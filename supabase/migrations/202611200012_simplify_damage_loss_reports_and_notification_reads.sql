begin;

drop function if exists public.list_damage_loss_reports();
create function public.list_damage_loss_reports()
returns table (
  report_id bigint,
  borrowing_id bigint,
  borrowing_item_id bigint,
  equipment_name text,
  asset_code text,
  borrower_name text,
  borrower_email text,
  report_type text,
  description text,
  photo_path text,
  created_at timestamptz,
  quantity_affected integer,
  quantity_deducted boolean,
  is_recovered boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can review damage and loss reports.';
  end if;

  return query
  select d.report_id, b.borrowing_id, bi.borrowing_item_id, e.equipment_name::text,
    e.asset_code::text, concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    br.email::text, d.report_type, d.description, d.photo_path, d.created_at,
    d.quantity_affected, d.quantity_deducted, d.is_recovered
  from public.damage_loss_reports d
  join public.borrowing_items bi using (borrowing_item_id)
  join public.borrowings b using (borrowing_id)
  join public.equipment e using (equipment_id)
  join public.borrowers br using (borrower_id)
  order by d.created_at desc;
end;
$$;
revoke all on function public.list_damage_loss_reports() from public, anon;
grant execute on function public.list_damage_loss_reports() to authenticated;

revoke all on function public.resolve_damage_loss_report(bigint, text, text)
  from public, anon, authenticated;
revoke all on function public.resolve_damage_loss_report(bigint, text, text, boolean)
  from public, anon, authenticated;

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
        and p.role in ('admin', 'property_custodian', 'staff')
    ) then
    raise exception 'Sign in with a verified account to update notifications.';
  end if;

  update public.notifications
  set is_read = true
  where notification_id = p_notification_id and user_id = v_actor and not is_read;
end;
$$;
revoke all on function public.mark_notification_read(bigint) from public, anon;
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
revoke all on function public.mark_all_notifications_read() from public, anon;
grant execute on function public.mark_all_notifications_read() to authenticated;

notify pgrst, 'reload schema';
commit;
