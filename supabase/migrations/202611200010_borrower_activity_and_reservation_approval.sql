begin;

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
  v_reported_quantity integer;
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

  select coalesce(sum(d.quantity_affected), 0)::integer into v_reported_quantity
  from public.damage_loss_reports d
  where d.borrowing_item_id = p_borrowing_item_id
    and d.quantity_deducted;
  if p_quantity_affected > v_quantity - v_reported_quantity then
    raise exception 'Reported quantity exceeds the remaining unreported quantity for this borrowed item.';
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
revoke all on function public.report_borrowing_item_condition(bigint, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.report_borrowing_item_condition(bigint, text, text, integer)
  to authenticated;

create or replace function public.list_equipment_tracking_records()
returns table (
  record_id text,
  record_type text,
  record_status text,
  borrowing_id bigint,
  reservation_id bigint,
  equipment_id bigint,
  equipment_name text,
  asset_code text,
  category_name text,
  equipment_image_url text,
  storage_location text,
  amount integer,
  total_quantity integer,
  borrower_name text,
  department text,
  destination text,
  start_date date,
  end_date date,
  pickup_at timestamptz,
  return_at timestamptz,
  profile_photo_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can view equipment tracking.';
  end if;

  return query
  select
    ('borrow-' || bi.borrowing_item_id::text)::text,
    'borrow'::text,
    case when bi.is_overdue then 'overdue' else 'released' end::text,
    b.borrowing_id,
    null::bigint,
    e.equipment_id,
    e.equipment_name::text,
    e.asset_code::text,
    c.category_name::text,
    e.image_url::text,
    e.storage_location::text,
    bi.quantity::integer,
    e.quantity::integer,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    coalesce(br.department, '')::text,
    b.destination::text,
    b.request_date::date,
    b.expected_return_date::date,
    bi.released_at,
    b.expected_return_date,
    br.profile_photo_path
  from public.borrowings b
  join public.borrowers br using (borrower_id)
  join public.borrowing_items bi using (borrowing_id)
  join public.equipment e using (equipment_id)
  join public.categories c using (category_id)
  where b.transaction_status = 'released' and bi.item_status = 'released'

  union all

  select
    ('reservation-' || r.reservation_id::text)::text,
    'reservation'::text,
    'reserved'::text,
    null::bigint,
    r.reservation_id,
    e.equipment_id,
    e.equipment_name::text,
    e.asset_code::text,
    c.category_name::text,
    e.image_url::text,
    e.storage_location::text,
    r.quantity::integer,
    e.quantity::integer,
    concat_ws(' ', br.first_name, br.middle_name, br.last_name)::text,
    coalesce(br.department, '')::text,
    r.destination::text,
    r.start_date,
    r.end_date,
    (r.start_date + r.start_time) at time zone 'Asia/Manila',
    (r.end_date + r.end_time) at time zone 'Asia/Manila',
    br.profile_photo_path
  from public.reservations r
  join public.borrowers br using (borrower_id)
  join public.equipment e using (equipment_id)
  join public.categories c using (category_id)
  where r.status = 'approved'
    and (r.end_date + r.end_time) at time zone 'Asia/Manila' >= now()
  order by 3, 17, 7;
end;
$$;
revoke all on function public.list_equipment_tracking_records() from public, anon;
grant execute on function public.list_equipment_tracking_records() to authenticated;

notify pgrst, 'reload schema';
commit;
