begin;

create or replace function public.require_borrower_return_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_old jsonb;
  v_new jsonb;
  v_old_status text;
  v_new_status text;
  v_borrowing_id bigint;
  v_borrowing_item_id bigint;
begin
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  v_borrowing_id := (v_new ->> 'borrowing_id')::bigint;

  if tg_table_name = 'borrowings' then
    v_old_status := v_old ->> 'transaction_status';
    v_new_status := v_new ->> 'transaction_status';
  elsif tg_table_name = 'borrowing_items' then
    v_old_status := v_old ->> 'item_status';
    v_new_status := v_new ->> 'item_status';
    v_borrowing_item_id := (v_new ->> 'borrowing_item_id')::bigint;
  else
    raise exception 'Return-request guard attached to an unsupported table.';
  end if;

  if v_new_status = 'returned' and v_old_status is distinct from 'returned' then
    if v_actor is not null and exists (
      select 1
      from public.damage_loss_reports d
      join public.borrowing_items bi using (borrowing_item_id)
      where bi.borrowing_id = v_borrowing_id
        and (v_borrowing_item_id is null or bi.borrowing_item_id = v_borrowing_item_id)
        and d.reporter_id = v_actor
        and d.quantity_deducted
        and (
          v_borrowing_item_id is not null
          or not exists (
            select 1 from public.borrowing_items active_item
            where active_item.borrowing_id = v_borrowing_id
              and active_item.item_status in ('requested', 'approved', 'released')
          )
        )
    ) then
      return new;
    end if;

    if v_actor is null or not public.is_equipment_manager_user() then
      raise exception 'Only an active administrator or property custodian can record returned equipment unless the borrower submitted a damage or loss report.';
    end if;
    if not exists (
      select 1
      from public.return_requests rr
      join public.borrowings b using (borrowing_id)
      join public.borrowers br using (borrower_id)
      where rr.borrowing_id = v_borrowing_id
        and rr.status = 'pending'
        and rr.requested_by = br.user_id
    ) then
      raise exception 'The borrower must request a return before a manager can record it as returned.';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.require_borrower_return_request() from public, anon, authenticated;

create or replace function public.audit_borrowing_workflow_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrowing_id bigint;
  v_borrower_user_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_event text;
  v_entity text;
  v_reported_by_actor boolean;
begin
  if tg_table_name = 'borrowings' then
    v_borrowing_id := new.borrowing_id;
    if new.transaction_status is not distinct from old.transaction_status then
      return new;
    end if;
    if v_actor is not null and not public.is_equipment_manager_user() then
      select br.user_id into v_borrower_user_id
      from public.borrowers br
      where br.borrower_id = new.borrower_id;
      select exists (
        select 1
        from public.damage_loss_reports d
        join public.borrowing_items bi using (borrowing_item_id)
        where bi.borrowing_id = new.borrowing_id
          and d.reporter_id = v_actor
          and d.quantity_deducted
          and not exists (
            select 1 from public.borrowing_items active_item
            where active_item.borrowing_id = new.borrowing_id
              and active_item.item_status in ('requested', 'approved', 'released')
          )
      ) into v_reported_by_actor;
      if not public.is_verified_active_user()
        or not exists (
          select 1 from public.profiles p
          where p.id = v_actor and p.role = 'staff' and p.account_status = 'active'
        )
        or v_borrower_user_id is distinct from v_actor
        or (new.transaction_status <> 'cancelled'
          and not (new.transaction_status = 'returned' and v_reported_by_actor)) then
        raise exception 'Only equipment managers or the owning borrower with a damage or loss report can change a borrowing status.';
      end if;
    elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
      raise exception 'A verified actor is required to change a borrowing status.';
    end if;
    v_before := jsonb_build_object('status', old.transaction_status);
    v_after := jsonb_build_object('status', new.transaction_status);
    v_entity := 'borrowing';
    v_event := 'status_changed';
  else
    v_borrowing_id := new.borrowing_id;
    if new.item_status is not distinct from old.item_status
      and new.is_overdue is not distinct from old.is_overdue then
      return new;
    end if;
    if v_actor is not null and not public.is_equipment_manager_user() then
      select br.user_id into v_borrower_user_id
      from public.borrowings b
      join public.borrowers br using (borrower_id)
      where b.borrowing_id = new.borrowing_id;
      select exists (
        select 1
        from public.damage_loss_reports d
        where d.borrowing_item_id = new.borrowing_item_id
          and d.reporter_id = v_actor
          and d.quantity_deducted
      ) into v_reported_by_actor;
      if not public.is_verified_active_user()
        or not exists (
          select 1 from public.profiles p
          where p.id = v_actor and p.role = 'staff' and p.account_status = 'active'
        )
        or v_borrower_user_id is distinct from v_actor
        or (new.item_status <> 'cancelled'
          and not (new.item_status = 'returned' and v_reported_by_actor)) then
        raise exception 'Only equipment managers or the owning borrower with a damage or loss report can change a borrowing item status.';
      end if;
    elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
      raise exception 'A verified actor is required to change a borrowing item status.';
    end if;
    v_before := jsonb_build_object('status', old.item_status, 'is_overdue', old.is_overdue);
    v_after := jsonb_build_object('status', new.item_status, 'is_overdue', new.is_overdue);
    v_entity := 'item';
    v_event := case
      when new.is_overdue is distinct from old.is_overdue and new.item_status is not distinct from old.item_status
        then 'overdue_flagged'
      else 'status_changed'
    end;
  end if;

  insert into public.borrowing_workflow_audit (
    borrowing_id, borrowing_item_id, entity_type, event_type, actor_id, before_values, after_values
  )
  values (
    v_borrowing_id,
    case when tg_table_name = 'borrowing_items' then new.borrowing_item_id else null end,
    v_entity,
    v_event,
    v_actor,
    v_before,
    v_after
  );
  return new;
end;
$$;
revoke all on function public.audit_borrowing_workflow_status() from public, anon, authenticated;

create or replace function public.enforce_equipment_unit_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_equipment_id bigint;
  v_unit_id bigint;
  v_tracking_mode text;
  v_quantity integer;
  v_out_of_service integer;
  v_non_retired integer;
  v_maintenance integer;
  v_actor uuid := (select auth.uid());
  v_report_transition boolean := false;
begin
  if tg_table_name = 'equipment' then
    v_equipment_id := case when tg_op = 'DELETE' then old.equipment_id else new.equipment_id end;
    if tg_op = 'UPDATE' then
      v_report_transition := new.out_of_service_quantity = old.out_of_service_quantity + 1
        and new.condition_status = 'damaged';
    end if;
  elsif tg_op = 'DELETE' then
    v_equipment_id := old.equipment_id;
    v_unit_id := old.unit_id;
  else
    v_equipment_id := new.equipment_id;
    v_unit_id := new.unit_id;
    if tg_op = 'UPDATE' then
      v_report_transition := old.status = 'borrowed'
        and new.status in ('maintenance', 'lost');
    end if;
  end if;

  if v_actor is not null and not public.is_equipment_manager_user()
    and not (
      v_report_transition
      and public.is_verified_active_user()
      and exists (
        select 1 from public.profiles p
        where p.id = v_actor and p.role = 'staff' and p.account_status = 'active'
      )
      and exists (
        select 1
        from public.damage_loss_reports d
        join public.borrowing_items bi using (borrowing_item_id)
        where d.reporter_id = v_actor
          and d.quantity_deducted
          and (
            (d.report_type = 'damage' and bi.condition_at_return = 'damaged')
            or (d.report_type = 'loss' and bi.condition_at_return = 'lost')
          )
          and bi.item_status = 'returned'
          and bi.equipment_id = v_equipment_id
          and (v_unit_id is null or bi.unit_id = v_unit_id)
      )
    ) then
    raise exception 'Only administrators and property custodians can change unit inventory.';
  elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified equipment manager is required to change unit inventory.';
  end if;

  select e.tracking_mode, e.quantity, e.out_of_service_quantity
    into v_tracking_mode, v_quantity, v_out_of_service
  from public.equipment e
  where e.equipment_id = v_equipment_id;
  if not found or v_tracking_mode <> 'unit' then
    return null;
  end if;

  select count(*) filter (where u.status <> 'retired'),
         count(*) filter (where u.status = 'maintenance')
    into v_non_retired, v_maintenance
  from public.equipment_units u
  where u.equipment_id = v_equipment_id;

  if v_non_retired <> v_quantity then
    raise exception 'Unit-tracked equipment quantity must equal its non-retired unit count.' using errcode = '23514';
  end if;
  if v_maintenance <> v_out_of_service then
    raise exception 'Unit-tracked out-of-service quantity must equal its maintenance unit count.' using errcode = '23514';
  end if;
  return null;
end;
$$;
revoke all on function public.enforce_equipment_unit_count() from public, anon, authenticated;

create or replace function public.report_borrowing_item_condition(
  p_borrowing_item_id bigint,
  p_report_type text,
  p_description text,
  p_quantity_affected integer default 1
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
  v_borrowing_id bigint;
  v_transaction_status text;
  v_item_status text;
  v_equipment_id bigint;
  v_quantity integer;
  v_reported_quantity integer;
  v_new_report_quantity integer;
  v_tracking_mode text;
  v_unit_id bigint;
  v_unit_status text;
  v_report_id bigint;
  v_old_report_type text;
  v_old_description text;
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

  select bi.equipment_id into v_equipment_id
  from public.borrowing_items bi
  where bi.borrowing_item_id = p_borrowing_item_id;
  if not found then
    raise exception 'Borrowed equipment item not found.';
  end if;
  perform 1 from public.equipment e
  where e.equipment_id = v_equipment_id and e.deleted_at is null
  for update;
  if not found then
    raise exception 'The borrowed equipment is no longer in the active inventory.';
  end if;
  select bi.borrowing_id into v_borrowing_id
  from public.borrowing_items bi
  where bi.borrowing_item_id = p_borrowing_item_id;
  perform 1 from public.borrowings b
  where b.borrowing_id = v_borrowing_id
  for update;
  select br.user_id, br.status, b.transaction_status, bi.item_status,
    bi.quantity, e.tracking_mode, bi.unit_id
    into v_borrower_user, v_borrower_status, v_transaction_status, v_item_status,
      v_quantity, v_tracking_mode, v_unit_id
  from public.borrowing_items bi
  join public.borrowings b using (borrowing_id)
  join public.borrowers br using (borrower_id)
  join public.equipment e using (equipment_id)
  where bi.borrowing_item_id = p_borrowing_item_id
  for update of bi;
  if not found then
    raise exception 'Borrowed equipment item not found.';
  end if;
  if v_borrower_status <> 'active'
    or v_transaction_status <> 'released'
    or v_item_status <> 'released' then
    raise exception 'Only an active borrowed item can be reported.';
  end if;
  if v_actor_role = 'staff' and v_borrower_user is distinct from v_actor then
    raise exception 'You can only report an item from your own borrowing.';
  elsif v_actor_role in ('admin', 'property_custodian') and not public.is_equipment_manager_user() then
    raise exception 'Only active equipment managers can report on behalf of a borrower.';
  end if;

  if p_report_type is null or p_report_type not in ('damage', 'loss') then
    raise exception 'Choose either damaged or lost for the report type.';
  end if;
  if p_description is null or length(trim(p_description)) < 1 or length(trim(p_description)) > 2000 then
    raise exception 'Report details must be between 1 and 2,000 characters.';
  end if;
  if p_quantity_affected is null or p_quantity_affected <> v_quantity then
    raise exception 'A damage or loss report completes the full borrowed quantity.';
  end if;
  if v_tracking_mode = 'unit' and (p_quantity_affected <> 1 or v_unit_id is null) then
    raise exception 'Unit-tracked equipment reports must affect its assigned unit.';
  end if;

  select coalesce(sum(d.quantity_affected), 0)::integer into v_reported_quantity
  from public.damage_loss_reports d
  where d.borrowing_item_id = p_borrowing_item_id
    and d.quantity_deducted;
  if v_reported_quantity > v_quantity then
    raise exception 'Existing damage or loss reports exceed the borrowed quantity. Contact equipment staff.';
  end if;
  v_new_report_quantity := v_quantity - v_reported_quantity;

  if v_new_report_quantity > 0 then
    insert into public.damage_loss_reports (
      borrowing_item_id, reporter_id, report_type, description,
      quantity_affected, quantity_deducted
    )
    values (
      p_borrowing_item_id, v_actor, p_report_type, trim(p_description),
      v_new_report_quantity, true
    )
    returning report_id into v_report_id;
  else
    select d.report_id, d.report_type, d.description
      into v_report_id, v_old_report_type, v_old_description
    from public.damage_loss_reports d
    where d.borrowing_item_id = p_borrowing_item_id
      and d.quantity_deducted
    order by d.created_at desc, d.report_id desc
    limit 1
    for update;
    if not found then
      raise exception 'The borrowed quantity has already been reported. Refresh your activity and try again.';
    end if;
    update public.damage_loss_reports
    set report_type = p_report_type,
        reporter_id = v_actor,
        description = left(
          format('Follow-up %s report: %s%sPrevious %s report: %s',
            upper(p_report_type), trim(p_description), E'\n\n',
            upper(v_old_report_type), coalesce(v_old_description, '')),
          2000
        ),
        updated_at = now()
    where report_id = v_report_id;

    insert into public.borrowing_workflow_audit (
      borrowing_id, borrowing_item_id, damage_report_id, entity_type, event_type,
      actor_id, before_values, after_values
    )
    values (
      v_borrowing_id, p_borrowing_item_id, v_report_id, 'damage_report', 'report_submitted',
      v_actor,
      jsonb_build_object('report_type', v_old_report_type, 'description', v_old_description),
      jsonb_build_object(
        'report_type', p_report_type, 'description', trim(p_description),
        'quantity_affected', v_quantity
      )
    );
    insert into public.notifications (user_id, borrowing_id, title, message, notification_type)
    select p.id, v_borrowing_id, 'Borrower reported damage or loss',
      'A borrower submitted a damage or loss report for borrowed equipment.',
      'damage_report_created'
    from public.profiles p
    where p.role in ('admin', 'property_custodian')
      and p.account_status = 'active';
  end if;

  if v_unit_id is not null then
    select u.status into v_unit_status
    from public.equipment_units u
    where u.unit_id = v_unit_id
    for update;
    if v_unit_status <> 'borrowed' then
      raise exception 'The assigned unit is no longer marked as borrowed.';
    end if;
    if p_report_type = 'damage' then
      update public.equipment_units
      set status = 'maintenance', updated_at = now()
      where unit_id = v_unit_id;
      update public.equipment
      set out_of_service_quantity = out_of_service_quantity + 1,
          condition_status = 'damaged',
          updated_at = now()
      where equipment_id = v_equipment_id;
      insert into public.unit_maintenance_log (unit_id, reason, started_at, recorded_by)
      values (v_unit_id, left(trim(p_description), 1000), now(), v_actor);
    else
      update public.equipment_units
      set status = 'lost', updated_at = now()
      where unit_id = v_unit_id;
    end if;
    insert into public.equipment_unit_audit (
      unit_id, equipment_id, actor_id, action, old_values, new_values
    )
    values (
      v_unit_id, v_equipment_id, v_actor, 'status_changed',
      jsonb_build_object('status', 'borrowed'),
      jsonb_build_object('status', case when p_report_type = 'damage' then 'maintenance' else 'lost' end,
        'damage_report_id', v_report_id)
    );
  elsif p_report_type = 'damage' then
    update public.equipment
    set condition_status = 'damaged', updated_at = now()
    where equipment_id = v_equipment_id;
  end if;

  update public.borrowing_items
  set item_status = 'returned',
      returned_at = now(),
      condition_at_return = case when p_report_type = 'damage' then 'damaged' else 'lost' end,
      is_overdue = false
  where borrowing_item_id = p_borrowing_item_id
    and item_status = 'released';
  if not found then
    raise exception 'The borrowing item could not be completed.';
  end if;

  update public.borrowings
  set transaction_status = 'returned', updated_at = now()
  where borrowing_id = v_borrowing_id
    and transaction_status = 'released'
    and not exists (
      select 1 from public.borrowing_items bi
      where bi.borrowing_id = v_borrowing_id
        and bi.item_status in ('requested', 'approved', 'released')
    );
  if exists (
    select 1 from public.borrowings b
    where b.borrowing_id = v_borrowing_id and b.transaction_status = 'returned'
  ) then
    update public.return_requests
    set status = 'completed', completed_at = now()
    where borrowing_id = v_borrowing_id and status = 'pending';
  end if;

  update public.equipment e
  set availability_status = case
    when e.availability_status = 'retired' then 'retired'
    when e.tracking_mode = 'unit' and exists (
      select 1 from public.equipment_units u
      where u.equipment_id = e.equipment_id and u.status = 'available'
    ) then 'available'
    when e.tracking_mode = 'unit' and exists (
      select 1 from public.equipment_units u
      where u.equipment_id = e.equipment_id and u.status = 'borrowed'
    ) then 'borrowed'
    when e.tracking_mode = 'unit' then 'maintenance'
    when e.quantity - e.out_of_service_quantity - coalesce((
      select sum(d.quantity_affected)
      from public.damage_loss_reports d
      join public.borrowing_items bi using (borrowing_item_id)
      where bi.equipment_id = e.equipment_id and d.quantity_deducted
    ), 0) <= 0 then 'maintenance'
    when coalesce((
      select sum(greatest(0, bi.quantity - coalesce((
        select sum(d.quantity_affected)
        from public.damage_loss_reports d
        where d.borrowing_item_id = bi.borrowing_item_id and d.quantity_deducted
      ), 0)))
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      where bi.equipment_id = e.equipment_id
        and bi.item_status in ('approved', 'released')
        and b.transaction_status in ('approved', 'released')
    ), 0) >= e.quantity - e.out_of_service_quantity - coalesce((
      select sum(d.quantity_affected)
      from public.damage_loss_reports d
      join public.borrowing_items bi using (borrowing_item_id)
      where bi.equipment_id = e.equipment_id and d.quantity_deducted
    ), 0) then 'borrowed'
    else 'available'
  end,
  updated_at = now()
  where e.equipment_id = v_equipment_id;

  return v_report_id;
end;
$$;
revoke all on function public.report_borrowing_item_condition(bigint, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.report_borrowing_item_condition(bigint, text, text, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;
