begin;

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
  join public.borrowings b using (borrowing_id)
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

notify pgrst, 'reload schema';
commit;
