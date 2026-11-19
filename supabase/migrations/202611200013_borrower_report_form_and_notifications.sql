begin;

create policy "active borrowers upload own item condition photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'item-condition-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_verified_active_user()
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and p.role = 'staff'
        and p.account_status = 'active'
    )
    and exists (
      select 1 from public.borrowers br
      where br.user_id = (select auth.uid())
        and br.status = 'active'
    )
  );

create policy "active borrowers delete own item condition photos"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'item-condition-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_verified_active_user()
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and p.role = 'staff'
        and p.account_status = 'active'
    )
    and exists (
      select 1 from public.borrowers br
      where br.user_id = (select auth.uid())
        and br.status = 'active'
    )
  );

create or replace function public.mark_notification_read(p_notification_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null
    or not exists (
      select 1 from auth.users u
      where u.id = v_actor and u.email_confirmed_at is not null
    )
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor
        and p.account_status <> 'inactive'
        and p.role in ('admin', 'property_custodian', 'staff')
    ) then
    raise exception 'Sign in with a verified account to update notifications.';
  end if;

  update public.notifications
  set is_read = true
  where notification_id = p_notification_id
    and user_id = v_actor
    and not is_read;
end;
$$;
revoke all on function public.mark_notification_read(bigint) from public, anon, authenticated;
grant execute on function public.mark_notification_read(bigint) to authenticated;

create or replace function public.mark_all_notifications_read()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_updated integer;
begin
  if v_actor is null
    or not exists (
      select 1 from auth.users u
      where u.id = v_actor and u.email_confirmed_at is not null
    )
    or not exists (
      select 1 from public.profiles p
      where p.id = v_actor
        and p.account_status <> 'inactive'
        and p.role in ('admin', 'property_custodian', 'staff')
    ) then
    raise exception 'Sign in with a verified account to update notifications.';
  end if;

  update public.notifications
  set is_read = true
  where user_id = v_actor and not is_read;
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;
revoke all on function public.mark_all_notifications_read() from public, anon, authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;

create or replace function public.notify_damage_loss_report_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_actor_role text;
  v_borrower_user uuid;
  v_borrower_name text;
  v_borrowing_id bigint;
  v_equipment_name text;
  v_report_kind text;
  v_reported_at text;
begin
  if tg_op = 'UPDATE' and new.resolution_status is not distinct from old.resolution_status then
    return new;
  end if;

  if v_actor is not null then
    if not public.is_verified_active_user() then
      raise exception 'A verified active account is required to report damage or loss.';
    end if;
    select p.role into v_actor_role
    from public.profiles p
    where p.id = v_actor and p.account_status = 'active';

    if v_actor_role in ('admin', 'property_custodian') then
      if not public.is_equipment_manager_user() then
        raise exception 'Only active equipment managers can change damage or loss reports.';
      end if;
    elsif tg_op = 'INSERT' and v_actor_role = 'staff'
      and new.reporter_id = v_actor
      and exists (
        select 1
        from public.borrowing_items bi
        join public.borrowings b using (borrowing_id)
        join public.borrowers br using (borrower_id)
        where bi.borrowing_item_id = new.borrowing_item_id
          and bi.item_status = 'released'
          and b.transaction_status = 'released'
          and br.user_id = v_actor
          and br.status = 'active'
      ) then
      null;
    else
      raise exception 'Only an equipment manager or the borrower of an active item can submit a report.';
    end if;
  elsif session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified account is required to change a damage or loss report.';
  end if;

  select b.borrowing_id, br.user_id,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name),
    e.equipment_name
    into v_borrowing_id, v_borrower_user, v_borrower_name, v_equipment_name
  from public.borrowing_items bi
  join public.borrowings b using (borrowing_id)
  join public.borrowers br using (borrower_id)
  join public.equipment e using (equipment_id)
  where bi.borrowing_item_id = new.borrowing_item_id;
  if not found or v_borrower_user is null then
    raise exception 'The damage or loss report has no linked borrower.';
  end if;

  v_report_kind := case when new.report_type = 'loss' then 'lost' else 'damaged' end;
  v_reported_at := to_char(new.created_at at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI');

  if tg_op = 'INSERT' and v_actor_role = 'staff' then
    insert into public.notifications (user_id, borrowing_id, title, message, notification_type)
    select p.id, v_borrowing_id,
      'Borrower reported ' || v_report_kind || ' equipment',
      format('%s reported %s equipment "%s" on %s.',
        v_borrower_name, v_report_kind, v_equipment_name, v_reported_at),
      'damage_report_created'
    from public.profiles p
    where p.role in ('admin', 'property_custodian')
      and p.account_status = 'active';
  elsif v_borrower_user is distinct from v_actor then
    insert into public.notifications (user_id, borrowing_id, title, message, notification_type)
    values (
      v_borrower_user,
      v_borrowing_id,
      'Damage or loss report recorded',
      format('A property manager recorded a %s report for "%s" on %s. Please return the item to the property custodian.',
        v_report_kind, v_equipment_name, v_reported_at),
      'damage_report_updated'
    );
  end if;
  return new;
end;
$$;
revoke all on function public.notify_damage_loss_report_change() from public, anon, authenticated;

create or replace function public.report_borrowing_item_condition_with_photo(
  p_borrowing_item_id bigint,
  p_report_type text,
  p_description text,
  p_quantity_affected integer,
  p_photo_path text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_actor_role text;
  v_borrower_user uuid;
  v_borrower_status text;
  v_transaction_status text;
  v_item_status text;
  v_equipment_id bigint;
  v_borrowing_id bigint;
  v_report_id bigint;
begin
  if v_actor is null or not public.is_verified_active_user() then
    raise exception 'Sign in with a verified active account to report damaged or lost equipment.';
  end if;

  select p.role into v_actor_role
  from public.profiles p
  where p.id = v_actor and p.account_status = 'active';
  if v_actor_role is null or v_actor_role not in ('admin', 'property_custodian', 'staff') then
    raise exception 'An active equipment account is required to submit a report.';
  end if;

  select br.user_id, bi.equipment_id, bi.borrowing_id
    into v_borrower_user, v_equipment_id, v_borrowing_id
  from public.borrowing_items bi
  join public.borrowers br using (borrower_id)
  where bi.borrowing_item_id = p_borrowing_item_id;
  if not found then
    raise exception 'Borrowed equipment item not found.';
  end if;
  if v_actor_role = 'staff' and v_borrower_user is distinct from v_actor then
    raise exception 'You can only report an item from your own borrowing.';
  elsif v_actor_role in ('admin', 'property_custodian') and not public.is_equipment_manager_user() then
    raise exception 'Only active equipment managers can report on behalf of a borrower.';
  end if;

  perform 1 from public.equipment e
  where e.equipment_id = v_equipment_id and e.deleted_at is null
  for update;
  if not found then
    raise exception 'The borrowed equipment is no longer in the active inventory.';
  end if;
  perform 1 from public.borrowings b
  where b.borrowing_id = v_borrowing_id
  for update;
  if not found then
    raise exception 'Borrowing record not found.';
  end if;
  select br.status, b.transaction_status, bi.item_status
    into v_borrower_status, v_transaction_status, v_item_status
  from public.borrowing_items bi
  join public.borrowings b using (borrowing_id)
  join public.borrowers br using (borrower_id)
  where bi.borrowing_item_id = p_borrowing_item_id
  for update of bi;
  if not found then
    raise exception 'Borrowed equipment item not found.';
  end if;

  if exists (
    select 1 from public.damage_loss_reports d
    where d.borrowing_item_id = p_borrowing_item_id
  ) then
    raise exception 'A damage or loss report has already been submitted for this item.';
  end if;
  if v_borrower_status <> 'active'
    or v_transaction_status <> 'released'
    or v_item_status <> 'released' then
    raise exception 'Only an active borrowed item can be reported.';
  end if;
  if not public.workflow_photo_path_is_valid(p_photo_path, v_actor) then
    raise exception 'The report photo path is invalid.';
  end if;

  v_report_id := public.report_borrowing_item_condition(
    p_borrowing_item_id, p_report_type, p_description, p_quantity_affected
  );

  update public.damage_loss_reports
  set photo_path = p_photo_path,
      updated_at = now()
  where report_id = v_report_id
    and reporter_id = v_actor;
  if not found then
    raise exception 'The damage or loss report could not be saved.';
  end if;

  return v_report_id;
end;
$$;
revoke all on function public.report_borrowing_item_condition_with_photo(bigint, text, text, integer, text)
  from public, anon, authenticated;
grant execute on function public.report_borrowing_item_condition_with_photo(bigint, text, text, integer, text)
  to authenticated;

revoke all on function public.report_borrowing_item_condition(bigint, text, text, integer)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
