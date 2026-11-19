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

  select b.borrowing_id, br.user_id
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

do $$
declare
  v_trigger record;
begin
  for v_trigger in
    select t.tgname
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_proc p on p.oid = t.tgfoid
    where t.tgrelid = 'public.damage_loss_reports'::regclass
      and not t.tgisinternal
      and p.pronamespace = 'public'::regnamespace
      and (
        p.proname in ('audit_damage_loss_report_status', 'audit_damage_loss_report_status_change')
        or pg_catalog.pg_get_functiondef(p.oid)
          ilike '%Only equipment managers can change damage report status%'
      )
  loop
    execute format('drop trigger %I on public.damage_loss_reports', v_trigger.tgname);
  end loop;

  for v_trigger in
    select t.tgname
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_proc p on p.oid = t.tgfoid
    where t.tgrelid = 'public.damage_loss_reports'::regclass
      and not t.tgisinternal
      and p.pronamespace = 'public'::regnamespace
      and p.proname = 'notify_damage_loss_report_change'
  loop
    execute format('drop trigger %I on public.damage_loss_reports', v_trigger.tgname);
  end loop;
end;
$$;

drop function if exists public.audit_damage_loss_report_status();

create trigger audit_damage_loss_report_status_change
  after insert or update on public.damage_loss_reports
  for each row execute function public.audit_damage_loss_report_status_change();
create trigger notify_damage_loss_report_created
  after insert on public.damage_loss_reports
  for each row execute function public.notify_damage_loss_report_change();
create trigger notify_damage_loss_report_status_changed
  after update of resolution_status on public.damage_loss_reports
  for each row execute function public.notify_damage_loss_report_change();

notify pgrst, 'reload schema';
commit;
