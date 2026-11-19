\set ON_ERROR_STOP on
begin;

do $$
declare
  v_admin uuid;
  v_custodian uuid;
  v_staff uuid;
  v_staff_email text;
  v_category_id bigint;
  v_equipment_id bigint;
begin
  if to_regclass('public.profiles') is null
    or to_regclass('public.borrowers') is null
    or to_regclass('public.account_access_audit_log') is null then
    raise exception 'Account and account-audit tables must remain in Supabase.';
  end if;
  if not has_column_privilege('authenticated', 'public.borrowers', 'user_id', 'select') then
    raise exception 'Authenticated borrower queries require the linked user_id column grant.';
  end if;
  if has_function_privilege('authenticated', 'public.admin_deactivate_borrower_account(uuid)', 'execute')
    or has_function_privilege('authenticated', 'public.admin_anonymize_inactive_borrower(uuid)', 'execute')
    or has_function_privilege('authenticated', 'public.admin_update_profile_access(uuid, text, text)', 'execute') then
    raise exception 'Authenticated administrators must not be able to deactivate, anonymize, or delete accounts.';
  end if;
  if not has_function_privilege('authenticated', 'public.set_profile_role(uuid, text)', 'execute') then
    raise exception 'Authenticated administrators must retain role-assignment access.';
  end if;

  select p.id into v_admin
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role = 'admin' and p.account_status = 'active' and u.email_confirmed_at is not null
  order by p.created_at limit 1;
  select p.id into v_custodian
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role = 'property_custodian' and p.account_status = 'active' and u.email_confirmed_at is not null
  order by p.created_at limit 1;
  select p.id, u.email into v_staff, v_staff_email
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.borrowers b on b.user_id = p.id
  where p.role = 'staff' and p.account_status = 'active' and b.status = 'active'
    and u.email_confirmed_at is not null
  order by p.created_at limit 1;
  select c.category_id into v_category_id from public.categories c order by c.category_id limit 1;
  if v_admin is null or v_custodian is null or v_staff is null or v_category_id is null then
    raise exception 'Role permission tests require active admin, property custodian, borrower, and category fixtures.';
  end if;

  insert into public.equipment (asset_code, equipment_name, category_id, quantity, tracking_mode, availability_status)
  values ('ROLE-PERM-' || replace(gen_random_uuid()::text, '-', ''), 'Role permission test equipment',
    v_category_id, 0, 'unit', 'available')
  returning equipment_id into v_equipment_id;
  perform set_config('role_permissions.admin_id', v_admin::text, true);
  perform set_config('role_permissions.custodian_id', v_custodian::text, true);
  perform set_config('role_permissions.staff_id', v_staff::text, true);
  perform set_config('role_permissions.staff_email', v_staff_email, true);
  perform set_config('role_permissions.equipment_id', v_equipment_id::text, true);
end;
$$;

select set_config('request.jwt.claim.sub', current_setting('role_permissions.custodian_id'), true);
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('role_permissions.custodian_id'),
  'role', 'authenticated'
)::text, true);
set local role authenticated;

do $$
declare
  v_equipment_id bigint := current_setting('role_permissions.equipment_id')::bigint;
  v_custodian uuid := current_setting('role_permissions.custodian_id')::uuid;
  v_staff uuid := current_setting('role_permissions.staff_id')::uuid;
  v_admin uuid := current_setting('role_permissions.admin_id')::uuid;
  v_staff_email text := current_setting('role_permissions.staff_email');
  v_rows integer;
  v_custodian_equipment_id bigint;
  v_unit_id bigint;
  v_second_unit_id bigint;
  v_borrowing_id bigint;
  v_item_id bigint;
  v_report_id bigint;
  v_asset_tag text;
  v_admin_count integer;
  v_error text;
  v_feedback_thread_id bigint;
  v_thread_to_delete_id bigint;
  v_feedback_reply_id bigint;
begin
  if not exists (
    select 1 from public.borrowers where user_id = v_staff
  ) then
    raise exception 'An equipment custodian could not read linked borrower records.';
  end if;

  update public.equipment set description = 'custodian can edit equipment'
  where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then raise exception 'A property custodian could not edit equipment.'; end if;

  insert into public.equipment (asset_code, equipment_name, category_id, quantity)
  values ('CUSTODIAN-' || replace(gen_random_uuid()::text, '-', ''), 'Custodian-created equipment',
    (select category_id from public.equipment where equipment_id = v_equipment_id), 1)
  returning equipment_id into v_custodian_equipment_id;
  if not exists (
    select 1 from public.equipment
    where equipment_id = v_custodian_equipment_id and equipment_name = 'Custodian-created equipment'
  ) then raise exception 'A property custodian could not add equipment.'; end if;
  perform public.delete_equipment(v_custodian_equipment_id);

  delete from public.equipment where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then raise exception 'A property custodian deleted catalog equipment directly.'; end if;

  if (
    select count(*) from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname in (
        'equipment managers upload images',
        'equipment managers update images',
        'equipment managers delete images'
      )
  ) <> 3 or exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname in (
        'admins upload equipment images',
        'admins update equipment images',
        'admins delete equipment images'
      )
  ) or (
    select count(*) from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname in (
        'equipment managers upload images',
        'equipment managers update images',
        'equipment managers delete images'
      )
      and coalesce(qual, '') || coalesce(with_check, '') like '%is_equipment_manager_user%'
  ) <> 3 then
    raise exception 'Equipment image write policies must be available to active equipment managers.';
  end if;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_staff, 'email', v_staff_email, 'role', 'authenticated'
  )::text, true);
  insert into public.feedback_threads (author_id, author_name, title, category, message)
  values (v_staff, 'Permission Test Borrower', 'Custodian comment deletion test', 'issue', 'Test thread.')
  returning id into v_feedback_thread_id;
  insert into public.feedback_replies (thread_id, author_id, author_name, message)
  values (v_feedback_thread_id, v_staff, 'Permission Test Borrower', 'Test comment.')
  returning id into v_feedback_reply_id;
  insert into public.feedback_threads (author_id, author_name, title, category, message)
  values (v_staff, 'Permission Test Borrower', 'Custodian thread deletion test', 'suggestion', 'Thread to delete.')
  returning id into v_thread_to_delete_id;
  insert into public.feedback_replies (thread_id, author_id, author_name, message)
  values (v_thread_to_delete_id, v_staff, 'Permission Test Borrower', 'Cascade test comment.');

  perform set_config('request.jwt.claim.sub', v_custodian::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_custodian, 'role', 'authenticated'
  )::text, true);
  delete from public.feedback_replies where id = v_feedback_reply_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then raise exception 'A property custodian could not delete a feedback comment.'; end if;
  delete from public.feedback_threads where id = v_thread_to_delete_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then raise exception 'A property custodian could not delete a feedback thread.'; end if;

  begin
    perform public.convert_equipment_to_unit_tracking(v_equipment_id, '[]'::jsonb);
    raise exception 'A property custodian converted catalog equipment.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'A property custodian converted catalog equipment.' then raise; end if;
    if v_error not like '%Only administrators can convert equipment%' then raise; end if;
  end;

  v_unit_id := public.add_equipment_unit(v_equipment_id, 'ROLE-UNIT-' || replace(gen_random_uuid()::text, '-', ''));
  v_second_unit_id := public.add_equipment_unit(v_equipment_id, 'ROLE-UNIT-' || replace(gen_random_uuid()::text, '-', ''));
  perform public.set_equipment_unit_status(v_second_unit_id, 'maintenance', 'permission test');
  perform public.set_equipment_unit_status(v_second_unit_id, 'available');
  select asset_tag into v_asset_tag from public.equipment_units where unit_id = v_unit_id;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_staff, 'email', v_staff_email, 'role', 'authenticated'
  )::text, true);
  v_borrowing_id := public.request_equipment_borrowing(
    v_equipment_id, 'Role permission test', 'Role test location', now() + interval '2 days', 1
  );
  select borrowing_item_id into v_item_id
  from public.borrowing_items where borrowing_id = v_borrowing_id;

  perform set_config('request.jwt.claim.sub', v_custodian::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_custodian, 'role', 'authenticated'
  )::text, true);
  perform public.review_borrowing_request(v_borrowing_id, 'approve', null);
  perform public.release_equipment_borrowing_units(
    v_borrowing_id,
    jsonb_build_array(jsonb_build_object('borrowing_item_id', v_item_id, 'unit_id', v_unit_id)),
    'good'
  );
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_staff, 'email', v_staff_email, 'role', 'authenticated'
  )::text, true);
  v_report_id := public.report_borrowing_item_condition(
    v_item_id, 'damage', 'Borrower-reported damage for permission test', 1
  );
  if not exists (
    select 1 from public.damage_loss_reports
    where report_id = v_report_id and reporter_id = v_staff
      and report_type = 'damage'
      and description = 'Borrower-reported damage for permission test'
      and resolution_status = 'open'
  ) then raise exception 'A borrower could not submit a damage report for their active item.'; end if;
  begin
    perform public.report_borrowing_item_condition(
      v_item_id, 'damage', 'Duplicate open report', 1
    );
    raise exception 'A borrower created a duplicate unresolved report.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'A borrower created a duplicate unresolved report.' then raise; end if;
    if v_error not like '%unresolved report of this type already exists%' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_custodian::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_custodian, 'role', 'authenticated'
  )::text, true);
  if not exists (
    select 1
    from public.list_damage_loss_reports()
    where report_id = v_report_id
      and description = 'Borrower-reported damage for permission test'
  ) then raise exception 'A manager could not load the borrower comment in damage and loss reports.'; end if;
  begin
    perform public.complete_equipment_unit_return(v_item_id, 'good', v_asset_tag, null, null);
    raise exception 'A property custodian returned equipment without a borrower request.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'A property custodian returned equipment without a borrower request.' then raise; end if;
    if v_error not like '%borrower must request a return%' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_staff, 'email', v_staff_email, 'role', 'authenticated'
  )::text, true);
  perform public.request_equipment_return(v_borrowing_id);

  perform set_config('request.jwt.claim.sub', v_custodian::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_custodian, 'role', 'authenticated'
  )::text, true);
  if not exists (
    select 1 from public.return_requests
    where borrowing_id = v_borrowing_id and status = 'pending'
  ) then raise exception 'A property custodian could not read the borrower return request.'; end if;
  perform public.complete_equipment_unit_return(v_item_id, 'good', v_asset_tag, null, null);
  if not exists (
    select 1 from public.borrowing_items
    where borrowing_item_id = v_item_id and item_status = 'returned' and returned_at is not null
  ) then raise exception 'A property custodian could not complete the release-and-return workflow.'; end if;

  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_staff, 'email', v_staff_email, 'role', 'authenticated'
  )::text, true);
  update public.equipment set description = 'staff write must be denied'
  where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then raise exception 'Staff updated the equipment catalog directly.'; end if;
  begin
    insert into public.equipment (asset_code, equipment_name, category_id, quantity)
    values ('STAFF-INSERT-MUST-FAIL', 'Unauthorized catalog insert',
      (select category_id from public.equipment where equipment_id = v_equipment_id), 1);
    raise exception 'Staff inserted equipment directly.';
  exception when insufficient_privilege then null;
  end;
  delete from public.equipment where equipment_id = v_equipment_id;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then raise exception 'Staff deleted catalog equipment directly.'; end if;
  begin
    perform public.delete_equipment(v_equipment_id);
    raise exception 'Staff called delete_equipment.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called delete_equipment.' then raise; end if;
    if v_error not like '%Only administrators and property custodians can remove equipment%' then raise; end if;
  end;
  begin
    perform public.convert_equipment_to_unit_tracking(v_equipment_id, '[]'::jsonb);
    raise exception 'Staff converted catalog equipment.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff converted catalog equipment.' then raise; end if;
    if v_error not like '%Only administrators can convert equipment%' then raise; end if;
  end;
  begin
    perform public.add_equipment_unit(v_equipment_id, 'STAFF-UNIT-MUST-FAIL');
    raise exception 'Staff called add_equipment_unit.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called add_equipment_unit.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.set_equipment_unit_status(v_second_unit_id, 'maintenance', 'unauthorized');
    raise exception 'Staff called set_equipment_unit_status.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called set_equipment_unit_status.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.release_equipment_borrowing_units(v_borrowing_id, '[]'::jsonb, 'good');
    raise exception 'Staff called release_equipment_borrowing_units.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called release_equipment_borrowing_units.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.complete_equipment_unit_return(v_item_id, 'good', v_asset_tag, null, null);
    raise exception 'Staff called complete_equipment_unit_return.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called complete_equipment_unit_return.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.review_equipment_reservation(-1, 'approve', null);
    raise exception 'Staff called review_equipment_reservation.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called review_equipment_reservation.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.mark_reservation_picked_up(-1);
    raise exception 'Staff called mark_reservation_picked_up.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called mark_reservation_picked_up.' then raise; end if;
    if v_error not like '%Only administrators and property custodians%' then raise; end if;
  end;
  begin
    perform public.set_profile_role(v_staff, 'admin');
    raise exception 'Staff called set_profile_role.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'Staff called set_profile_role.' then raise; end if;
    if v_error not like '%Only an active administrator%' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub', v_custodian::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_custodian, 'role', 'authenticated'
  )::text, true);
  perform public.delete_equipment(v_equipment_id);
  if not exists (
    select 1 from public.equipment
    where equipment_id = v_equipment_id and deleted_at is not null and deleted_by = v_custodian
  ) then raise exception 'A property custodian could not remove inactive equipment.'; end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_admin, 'role', 'authenticated'
  )::text, true);
  select count(*) into v_admin_count from public.profiles
  where role = 'admin' and account_status = 'active';
  begin
    perform public.set_profile_role(v_admin, 'property_custodian');
    raise exception 'An admin demoted themselves.';
  exception when raise_exception then
    get stacked diagnostics v_error = message_text;
    if v_error = 'An admin demoted themselves.' then raise; end if;
    if v_admin_count = 1 and v_error not like '%last active administrator%' then raise; end if;
    if v_admin_count > 1 and v_error not like '%cannot change their own role or account status%' then raise; end if;
  end;
  if not exists (
    select 1 from public.profiles where id = v_admin and role = 'admin' and account_status = 'active'
  ) then raise exception 'An admin self-change attempt modified the active admin.'; end if;

  perform public.set_profile_role(v_staff, 'property_custodian');
  if not exists (
    select 1 from public.profiles p join public.borrowers b on b.user_id = p.id
    where p.id = v_staff and p.role = 'property_custodian'
      and p.account_status = 'active' and b.status = 'active'
  ) then raise exception 'set_profile_role must keep the linked borrower status synchronized.'; end if;
end;
$$;

reset role;
rollback;
