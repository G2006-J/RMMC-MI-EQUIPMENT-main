begin;

delete from public.notifications;

create or replace function public.delete_equipment(p_equipment_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null
    or not public.is_verified_active_user()
    or not exists (
      select 1
      from public.profiles p
      where p.id = v_actor
        and p.role in ('admin', 'property_custodian')
        and p.account_status = 'active'
    ) then
    raise exception 'Only administrators and property custodians can remove equipment.';
  end if;

  if exists (
    select 1
    from public.borrowing_items bi
    join public.borrowings b on b.borrowing_id = bi.borrowing_id
    where bi.equipment_id = p_equipment_id
      and b.transaction_status in (
        'pending', 'requested', 'approved', 'borrowed', 'released', 'overdue', 'return_requested'
      )
  ) or exists (
    select 1
    from public.reservations r
    where r.equipment_id = p_equipment_id
      and r.status in ('pending', 'approved')
  ) then
    raise exception 'Equipment with an active borrowing request, loan, or reservation cannot be removed.';
  end if;

  update public.equipment
  set deleted_at = now(), deleted_by = v_actor
  where equipment_id = p_equipment_id and deleted_at is null;
  if not found then
    raise exception 'Equipment was not found or is already removed.';
  end if;
end;
$$;
revoke all on function public.delete_equipment(bigint) from public, anon;
grant execute on function public.delete_equipment(bigint) to authenticated;

notify pgrst, 'reload schema';
commit;
