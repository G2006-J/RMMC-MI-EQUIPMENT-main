begin;

alter table public.borrowing_workflow_audit
  drop constraint if exists borrowing_workflow_audit_event_type_check,
  add constraint borrowing_workflow_audit_event_type_check
    check (event_type in ('status_changed', 'overdue_flagged', 'report_submitted'));

create or replace function public.audit_damage_loss_report_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_actor_role text;
  v_borrowing_id bigint;
  v_borrower_user uuid;
  v_before jsonb;
  v_event_type text;
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

  select bi.borrowing_id, br.user_id
    into v_borrowing_id, v_borrower_user
  from public.borrowing_items bi
  join public.borrowings b using (borrowing_id)
  join public.borrowers br using (borrower_id)
  where bi.borrowing_item_id = new.borrowing_item_id;
  if not found then
    raise exception 'The borrowing item for this damage report was not found.';
  end if;

  if tg_op = 'UPDATE' then
    v_before := jsonb_build_object('resolution_status', old.resolution_status);
    v_event_type := 'status_changed';
  else
    v_event_type := 'report_submitted';
  end if;

  insert into public.borrowing_workflow_audit (
    borrowing_id, borrowing_item_id, damage_report_id, entity_type, event_type,
    actor_id, before_values, after_values
  )
  values (
    v_borrowing_id, new.borrowing_item_id, new.report_id,
    'damage_report', v_event_type, v_actor, v_before,
    jsonb_build_object(
      'report_type', new.report_type,
      'resolution_status', new.resolution_status,
      'quantity_affected', new.quantity_affected
    )
  );
  return new;
end;
$$;
revoke all on function public.audit_damage_loss_report_status_change() from public, anon, authenticated;

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
  v_borrowing_id bigint;
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

  select b.borrowing_id, br.user_id
    into v_borrowing_id, v_borrower_user
  from public.borrowing_items bi
  join public.borrowings b using (borrowing_id)
  join public.borrowers br using (borrower_id)
  where bi.borrowing_item_id = new.borrowing_item_id;
  if not found or v_borrower_user is null then
    raise exception 'The damage or loss report has no linked borrower.';
  end if;

  if tg_op = 'INSERT' and v_actor_role = 'staff' then
    insert into public.notifications (user_id, borrowing_id, title, message, notification_type)
    select p.id, v_borrowing_id, 'Borrower reported damage or loss',
      'A borrower submitted a damage or loss report for borrowed equipment.',
      'damage_report_created'
    from public.profiles p
    where p.role in ('admin', 'property_custodian') and p.account_status = 'active';
  elsif v_borrower_user is distinct from v_actor then
    insert into public.notifications (user_id, borrowing_id, title, message, notification_type)
    values (
      v_borrower_user,
      v_borrowing_id,
      'Damage or loss report updated',
      case when tg_op = 'UPDATE' and new.resolution_status in ('resolved', 'waived')
        then 'Staff updated the resolution of your damage or loss report.'
        else 'A damage or loss report was recorded for your borrowed equipment.'
      end,
      'damage_report_updated'
    );
  end if;
  return new;
end;
$$;
revoke all on function public.notify_damage_loss_report_change() from public, anon, authenticated;

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
  v_quantity integer;
  v_tracking_mode text;
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

  select br.user_id, br.status, b.borrowing_id, b.transaction_status,
    bi.item_status, bi.quantity, e.tracking_mode
    into v_borrower_user, v_borrower_status, v_borrowing_id, v_transaction_status,
      v_item_status, v_quantity, v_tracking_mode
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
  if p_quantity_affected is null or p_quantity_affected < 1 or p_quantity_affected > v_quantity then
    raise exception 'Affected quantity must be between 1 and the borrowed quantity.';
  end if;
  if v_tracking_mode = 'unit' and p_quantity_affected <> 1 then
    raise exception 'Unit-tracked equipment reports must affect one unit.';
  end if;
  if exists (
    select 1
    from public.damage_loss_reports d
    where d.borrowing_item_id = p_borrowing_item_id
      and d.report_type = p_report_type
      and d.resolution_status in ('open', 'under_review')
  ) then
    raise exception 'An unresolved report of this type already exists for the borrowed item.';
  end if;

  insert into public.damage_loss_reports (
    borrowing_item_id, reporter_id, report_type, description,
    quantity_affected, quantity_deducted
  )
  values (
    p_borrowing_item_id, v_actor, p_report_type, trim(p_description),
    p_quantity_affected, true
  )
  returning report_id into v_report_id;
  return v_report_id;
end;
$$;
revoke all on function public.report_borrowing_item_condition(bigint, text, text, integer) from public, anon, authenticated;
grant execute on function public.report_borrowing_item_condition(bigint, text, text, integer) to authenticated;

commit;
