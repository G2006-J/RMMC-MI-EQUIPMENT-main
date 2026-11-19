begin;

drop function public.resolve_damage_loss_report(bigint, text, text);
create function public.resolve_damage_loss_report(
  p_report_id bigint,
  p_resolution_status text,
  p_resolution_notes text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_old_status text;
  v_report_type text;
  v_equipment_id bigint;
  v_unit_id bigint;
  v_quantity integer;
  v_tracking_mode text;
  v_out_of_service_quantity integer;
  v_equipment_quantity integer;
  v_unit_status text;
  v_has_active_reports boolean;
  v_has_active_damage_reports boolean;
  v_active_borrowing_quantity integer;
  v_item_available boolean := false;
  v_unit_to_restore record;
  v_resolution_message text;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can resolve damage and loss reports.';
  end if;
  if p_resolution_status is null or p_resolution_status not in ('open', 'under_review', 'resolved', 'waived') then
    raise exception 'Choose a valid report resolution status.';
  end if;
  if p_resolution_status in ('resolved', 'waived')
    and nullif(trim(p_resolution_notes), '') is null then
    raise exception 'Resolution notes are required to close a damage or loss report.';
  end if;

  select d.resolution_status, d.report_type, e.equipment_id, bi.unit_id, bi.quantity, e.tracking_mode
    into v_old_status, v_report_type, v_equipment_id, v_unit_id, v_quantity, v_tracking_mode
  from public.damage_loss_reports d
  join public.borrowing_items bi using (borrowing_item_id)
  join public.equipment e using (equipment_id)
  where d.report_id = p_report_id
  for update of d, e;
  if not found then
    raise exception 'Damage or loss report not found.';
  end if;

  update public.damage_loss_reports
  set resolution_status = p_resolution_status,
      resolution_notes = nullif(trim(p_resolution_notes), ''),
      resolved_by = case when p_resolution_status in ('resolved', 'waived') then v_actor else null end,
      resolved_at = case when p_resolution_status in ('resolved', 'waived') then now() else null end,
      updated_at = now()
  where report_id = p_report_id;

  if v_report_type = 'damage' and v_unit_id is null and v_tracking_mode = 'quantity' then
    select quantity, out_of_service_quantity
      into v_equipment_quantity, v_out_of_service_quantity
    from public.equipment
    where equipment_id = v_equipment_id;

    if p_resolution_status = 'resolved' and v_old_status <> 'resolved' then
      v_out_of_service_quantity := greatest(0, v_out_of_service_quantity - v_quantity);
    elsif p_resolution_status in ('open', 'under_review', 'waived') and v_old_status = 'resolved' then
      v_out_of_service_quantity := least(v_equipment_quantity, v_out_of_service_quantity + v_quantity);
    end if;

    update public.equipment
    set out_of_service_quantity = v_out_of_service_quantity,
        updated_at = now()
    where equipment_id = v_equipment_id;
  end if;

  if v_unit_id is not null then
    select status into v_unit_status
    from public.equipment_units
    where unit_id = v_unit_id
    for update;

    if v_report_type = 'damage'
      and p_resolution_status in ('open', 'under_review', 'waived')
      and v_unit_status = 'available' then
      perform public.set_equipment_unit_status(
        v_unit_id, 'maintenance', 'Damage report ' || p_report_id::text, now(), null
      );
    end if;
  end if;

  select exists (
    select 1
    from public.damage_loss_reports d
    join public.borrowing_items bi using (borrowing_item_id)
    where bi.equipment_id = v_equipment_id
      and d.resolution_status in ('open', 'under_review', 'waived')
  ) into v_has_active_reports;

  select exists (
    select 1
    from public.damage_loss_reports d
    join public.borrowing_items bi using (borrowing_item_id)
    where bi.equipment_id = v_equipment_id
      and d.report_type = 'damage'
      and d.resolution_status in ('open', 'under_review', 'waived')
  ) into v_has_active_damage_reports;

  if v_report_type = 'damage'
    and p_resolution_status = 'resolved'
    and not v_has_active_reports
    and v_tracking_mode = 'unit' then
    for v_unit_to_restore in
      select distinct u.unit_id
      from public.damage_loss_reports d
      join public.borrowing_items bi using (borrowing_item_id)
      join public.equipment_units u on u.unit_id = bi.unit_id
      where bi.equipment_id = v_equipment_id
        and d.report_type = 'damage'
        and d.resolution_status = 'resolved'
        and u.status = 'maintenance'
        and not exists (
          select 1
          from public.damage_loss_reports other_report
          join public.borrowing_items other_item using (borrowing_item_id)
          where other_item.unit_id = u.unit_id
            and other_report.resolution_status in ('open', 'under_review', 'waived')
        )
      order by u.unit_id
    loop
      perform public.set_equipment_unit_status(
        v_unit_to_restore.unit_id, 'available', null, null, null
      );
    end loop;
  end if;

  select coalesce(sum(bi.quantity), 0)::integer
    into v_active_borrowing_quantity
  from public.borrowing_items bi
  join public.borrowings b using (borrowing_id)
  where bi.equipment_id = v_equipment_id
    and b.transaction_status in ('approved', 'released');

  update public.equipment e
  set condition_status = case
        when v_has_active_damage_reports then 'damaged'
        when v_report_type = 'damage' and p_resolution_status = 'resolved' then 'good'
        else e.condition_status
      end,
      availability_status = case
        when e.availability_status = 'retired' then 'retired'
        when v_has_active_reports or v_has_active_damage_reports then 'maintenance'
        when e.tracking_mode = 'unit'
          and not exists (
            select 1 from public.equipment_units u
            where u.equipment_id = e.equipment_id and u.status in ('available', 'borrowed')
          ) then 'maintenance'
        when e.tracking_mode = 'unit'
          and not exists (
            select 1 from public.equipment_units u
            where u.equipment_id = e.equipment_id and u.status = 'available'
          ) then 'borrowed'
        when e.tracking_mode = 'quantity'
          and (e.quantity - e.out_of_service_quantity) <= 0 then 'maintenance'
        when e.tracking_mode = 'quantity'
          and v_active_borrowing_quantity >= e.quantity - e.out_of_service_quantity then 'borrowed'
        else 'available'
      end,
      updated_at = now()
  where e.equipment_id = v_equipment_id;

  if v_report_type = 'damage' and p_resolution_status = 'resolved' and not v_has_active_reports then
    if v_unit_id is not null then
      select status into v_unit_status
      from public.equipment_units
      where unit_id = v_unit_id;
      v_item_available := v_unit_status = 'available';
    else
      select e.availability_status = 'available'
        into v_item_available
      from public.equipment e
      where e.equipment_id = v_equipment_id;
    end if;
  end if;

  if v_report_type = 'loss' then
    v_resolution_message := 'Resolution saved. The lost item remains unavailable until it is explicitly recovered.';
  elsif v_item_available then
    v_resolution_message := 'Resolution saved. Item marked as fixed and available.';
  elsif p_resolution_status = 'resolved' then
    v_resolution_message := 'Resolution saved. The item remains unavailable because another report, active borrowing, or maintenance still applies.';
  else
    v_resolution_message := 'Resolution saved. The item remains damaged and unavailable.';
  end if;

  return v_resolution_message;
end;
$$;
revoke all on function public.resolve_damage_loss_report(bigint, text, text) from public, anon;
grant execute on function public.resolve_damage_loss_report(bigint, text, text) to authenticated;

create or replace function public.equipment_period_has_capacity(
  p_equipment_id bigint,
  p_start_date date,
  p_end_date date,
  p_requested_quantity integer,
  p_exclude_borrowing_id bigint default null,
  p_exclude_reservation_id bigint default null
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text;
  v_quantity integer;
  v_oos integer;
  v_status text;
  v_condition text;
  v_capacity integer;
begin
  if (select auth.uid()) is null or not public.is_verified_active_user()
    or not exists (select 1 from public.profiles p where p.id = (select auth.uid())
      and p.role in ('admin', 'property_custodian', 'staff')) then return false; end if;
  select e.tracking_mode, e.quantity, e.out_of_service_quantity, e.availability_status, e.condition_status
    into v_mode, v_quantity, v_oos, v_status, v_condition
  from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null;
  if not found or p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date
    or v_condition = 'damaged'
    or exists (
      select 1
      from public.damage_loss_reports d
      join public.borrowing_items bi using (borrowing_item_id)
      where bi.equipment_id = p_equipment_id
        and d.resolution_status in ('open', 'under_review', 'waived')
    )
    or (v_mode = 'quantity' and v_status in ('maintenance', 'retired')) then return false; end if;
  if v_mode = 'unit' then
    select count(*)::integer into v_capacity from public.equipment_units u
    where u.equipment_id = p_equipment_id and u.status in ('available', 'borrowed');
  else
    v_capacity := v_quantity - v_oos;
  end if;
  if v_capacity < p_requested_quantity then return false; end if;
  return not exists (
    with occupied as (
      select b.request_date::date as start_date,
        case when b.expected_return_date::date < current_date then 'infinity'::date else b.expected_return_date::date end as end_date,
        bi.quantity
      from public.borrowings b join public.borrowing_items bi using (borrowing_id)
      where bi.equipment_id = p_equipment_id and b.transaction_status in ('approved', 'released')
        and (p_exclude_borrowing_id is null or b.borrowing_id <> p_exclude_borrowing_id)
        and (v_mode <> 'unit' or bi.item_status in ('approved', 'released'))
      union all
      select r.start_date, r.end_date, r.quantity from public.reservations r
      where r.equipment_id = p_equipment_id and r.status = 'approved'
        and (p_exclude_reservation_id is null or r.reservation_id <> p_exclude_reservation_id)
    ), candidates as (
      select p_start_date as d union select o.start_date from occupied o
      where o.start_date > p_start_date and o.start_date <= p_end_date
    )
    select 1 from candidates c where (
      select coalesce(sum(o.quantity), 0) from occupied o
      where o.start_date <= c.d and o.end_date >= c.d
    ) + p_requested_quantity > v_capacity
  );
end;
$$;
revoke all on function public.equipment_period_has_capacity(bigint, date, date, integer, bigint, bigint)
  from public, anon, authenticated;

create or replace function public.search_equipment_page(
  p_search text default null,
  p_category_id bigint default null,
  p_after_name text default null,
  p_after_id bigint default null
)
returns table (
  equipment_id bigint,
  asset_code text,
  equipment_name text,
  category_id bigint,
  category_name text,
  quantity integer,
  out_of_service_quantity integer,
  tracking_mode text,
  availability_status text,
  available_quantity integer,
  image_url text,
  storage_location text,
  brand text,
  model text,
  description text,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_verified_active_user() then
    raise exception 'Sign in with an active account to search equipment.';
  end if;
  if not exists (select 1 from public.profiles p where p.id = (select auth.uid())
    and p.role in ('staff', 'admin', 'property_custodian')) then
    raise exception 'This account cannot search equipment.';
  end if;
  return query
  select e.equipment_id, e.asset_code::text, e.equipment_name::text, e.category_id,
    c.category_name::text, e.quantity, e.out_of_service_quantity, e.tracking_mode,
    case
      when e.availability_status = 'retired' then 'retired'
      when e.condition_status = 'damaged' or exists (
        select 1
        from public.damage_loss_reports d
        join public.borrowing_items bi using (borrowing_item_id)
        where bi.equipment_id = e.equipment_id
          and d.resolution_status in ('open', 'under_review', 'waived')
      ) then 'maintenance'
      else e.availability_status
    end::text,
    case
      when e.condition_status = 'damaged' or exists (
        select 1
        from public.damage_loss_reports d
        join public.borrowing_items bi using (borrowing_item_id)
        where bi.equipment_id = e.equipment_id
          and d.resolution_status in ('open', 'under_review', 'waived')
      ) then 0
      when e.tracking_mode = 'unit' then greatest(0, (
        select count(*)::integer from public.equipment_units u
        where u.equipment_id = e.equipment_id and u.status = 'available'
      ) - coalesce(occupied.amount, 0))
      else greatest(0, e.quantity - e.out_of_service_quantity - coalesce(occupied.amount, 0))
    end::integer,
    e.image_url::text, e.storage_location::text, e.brand::text, e.model::text,
    e.description::text, count(*) over ()
  from public.equipment e join public.categories c using (category_id)
  left join lateral (
    select coalesce(sum(bi.quantity), 0)::integer amount from public.borrowing_items bi
    join public.borrowings b using (borrowing_id)
    where bi.equipment_id = e.equipment_id and b.transaction_status in ('approved', 'released')
      and b.request_date::date <= current_date and b.expected_return_date::date >= current_date
      and (e.tracking_mode <> 'unit' or b.transaction_status = 'approved')
  ) occupied on true
  where e.deleted_at is null
    and (p_category_id is null or e.category_id = p_category_id)
    and (nullif(trim(p_search), '') is null or lower(e.equipment_name) like lower(trim(p_search)) || '%'
      or lower(e.asset_code) like lower(trim(p_search)) || '%'
      or lower(coalesce(e.storage_location, '')) like lower(trim(p_search)) || '%')
    and (p_after_name is null or (e.equipment_name, e.equipment_id) > (p_after_name, p_after_id))
  order by e.equipment_name, e.equipment_id
  limit 20;
end;
$$;
revoke all on function public.search_equipment_page(text, bigint, text, bigint) from public, anon;
grant execute on function public.search_equipment_page(text, bigint, text, bigint) to authenticated;

commit;
