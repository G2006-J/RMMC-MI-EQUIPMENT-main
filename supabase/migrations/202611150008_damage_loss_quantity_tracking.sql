begin;

alter table public.damage_loss_reports
  add column quantity_affected integer not null default 1,
  add column quantity_deducted boolean not null default true,
  add column is_recovered boolean not null default false;

alter table public.damage_loss_reports
  add constraint damage_loss_quantity_affected_positive
    check (quantity_affected > 0);

update public.damage_loss_reports d
set quantity_affected = case when e.tracking_mode = 'unit' then 1 else greatest(bi.quantity, 1) end,
    quantity_deducted = case
      when d.report_type = 'damage' then d.resolution_status in ('open', 'under_review', 'waived')
      else true
    end
from public.borrowing_items bi
join public.equipment e using (equipment_id)
where bi.borrowing_item_id = d.borrowing_item_id;

update public.equipment e
set quantity = e.quantity + coalesce(losses.quantity, 0)
from (
  select bi.equipment_id, sum(reports.quantity)::integer as quantity
  from (
    select borrowing_item_id, max(quantity_affected) as quantity
    from public.damage_loss_reports
    where report_type = 'loss'
    group by borrowing_item_id
  ) reports
  join public.borrowing_items bi using (borrowing_item_id)
  join public.equipment tracked on tracked.equipment_id = bi.equipment_id
  where tracked.tracking_mode = 'quantity'
  group by bi.equipment_id
) losses
where e.equipment_id = losses.equipment_id;

update public.equipment e
set out_of_service_quantity = greatest(0, e.out_of_service_quantity - coalesce(damaged.quantity, 0))
from (
  select bi.equipment_id, sum(d.quantity_affected)::integer as quantity
  from public.damage_loss_reports d
  join public.borrowing_items bi using (borrowing_item_id)
  join public.equipment tracked on tracked.equipment_id = bi.equipment_id
  where tracked.tracking_mode = 'quantity'
    and d.report_type = 'damage'
    and d.quantity_deducted
  group by bi.equipment_id
) damaged
where e.equipment_id = damaged.equipment_id;

drop function public.list_damage_loss_reports();
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
  resolution_status text,
  resolution_notes text,
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
    br.email::text, d.report_type, d.description, d.photo_path, d.resolution_status,
    d.resolution_notes, d.created_at, d.quantity_affected, d.quantity_deducted, d.is_recovered
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

drop function if exists public.resolve_damage_loss_report(bigint, text, text);
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
  v_is_recovered boolean;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can resolve damage and loss reports.';
  end if;
  select d.is_recovered into v_is_recovered
  from public.damage_loss_reports d where d.report_id = p_report_id;
  if not found then raise exception 'Damage or loss report not found.'; end if;
  return public.resolve_damage_loss_report(
    p_report_id, p_resolution_status, p_resolution_notes, v_is_recovered
  );
end;
$$;
revoke all on function public.resolve_damage_loss_report(bigint, text, text) from public, anon;
grant execute on function public.resolve_damage_loss_report(bigint, text, text) to authenticated;

create or replace function public.resolve_damage_loss_report(
  p_report_id bigint,
  p_resolution_status text,
  p_resolution_notes text,
  p_is_recovered boolean
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
  v_old_deducted boolean;
  v_old_recovered boolean;
  v_quantity integer;
  v_equipment_id bigint;
  v_borrowing_item_id bigint;
  v_unit_id bigint;
  v_tracking_mode text;
  v_unit_status text;
  v_new_deducted boolean;
  v_borrowed boolean;
  v_other_open_report boolean;
  v_available integer;
  v_total integer;
  v_changed_quantity integer := 0;
  v_message text;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can resolve damage and loss reports.';
  end if;
  if p_resolution_status is null or p_resolution_status not in ('open', 'under_review', 'resolved', 'waived') then
    raise exception 'Choose a valid report resolution status.';
  end if;
  if p_is_recovered is null then
    raise exception 'Specify whether the lost item was physically recovered.';
  end if;
  if p_resolution_status in ('resolved', 'waived')
    and nullif(trim(p_resolution_notes), '') is null then
    raise exception 'Resolution notes are required to close a damage or loss report.';
  end if;

  select d.resolution_status, d.report_type, d.quantity_deducted, d.is_recovered,
    d.quantity_affected, bi.equipment_id, bi.borrowing_item_id, bi.unit_id, e.tracking_mode
    into v_old_status, v_report_type, v_old_deducted, v_old_recovered,
      v_quantity, v_equipment_id, v_borrowing_item_id, v_unit_id, v_tracking_mode
  from public.damage_loss_reports d
  join public.borrowing_items bi using (borrowing_item_id)
  join public.equipment e using (equipment_id)
  where d.report_id = p_report_id
  for update of d, e;
  if not found then
    raise exception 'Damage or loss report not found.';
  end if;
  if p_is_recovered and (v_report_type <> 'loss' or p_resolution_status <> 'resolved') then
    raise exception 'Only a resolved loss report can be marked recovered.';
  end if;

  select b.transaction_status in ('approved', 'released')
      and bi.item_status in ('approved', 'released')
    into v_borrowed
  from public.borrowing_items bi
  join public.borrowings b using (borrowing_id)
  where bi.borrowing_item_id = v_borrowing_item_id;
  v_new_deducted := case
    when v_report_type = 'damage' then p_resolution_status <> 'resolved'
    else not p_is_recovered
  end;
  if p_is_recovered and v_borrowed then
    raise exception 'Return the borrowed item before marking a loss report recovered.';
  end if;
  if v_borrowed and v_tracking_mode = 'quantity' then
    v_new_deducted := false;
  end if;

  if v_unit_id is not null then
    select status into v_unit_status
    from public.equipment_units
    where unit_id = v_unit_id
    for update;
    select exists (
      select 1
      from public.damage_loss_reports other_report
      join public.borrowing_items other_item using (borrowing_item_id)
      where other_report.report_id <> p_report_id
        and other_item.unit_id = v_unit_id
        and other_report.resolution_status in ('open', 'under_review', 'waived')
    ) into v_other_open_report;

    if v_report_type = 'damage' and v_new_deducted
      and v_unit_status = 'available' then
      perform public.set_equipment_unit_status(
        v_unit_id, 'maintenance', 'Damage report ' || p_report_id::text, now(), null
      );
    elsif v_report_type = 'damage' and not v_new_deducted
      and v_unit_status = 'maintenance' and not v_other_open_report then
      perform public.set_equipment_unit_status(v_unit_id, 'available', null, null, null);
    elsif v_report_type = 'loss' and p_is_recovered then
      if v_unit_status <> 'lost' or v_borrowed or v_other_open_report then
        raise exception 'Resolve other reports and return the lost unit before marking it recovered.';
      end if;
      update public.equipment_units
      set status = 'available', updated_at = now()
      where unit_id = v_unit_id;
      insert into public.equipment_unit_audit (
        unit_id, equipment_id, actor_id, action, old_values, new_values
      )
      values (
        v_unit_id, v_equipment_id, v_actor, 'status_changed',
        jsonb_build_object('status', 'lost'),
        jsonb_build_object('status', 'available', 'recovered_from_report_id', p_report_id)
      );
    elsif v_report_type = 'loss' and v_new_deducted and v_unit_status = 'available' then
      update public.equipment_units
      set status = 'lost', updated_at = now()
      where unit_id = v_unit_id;
      insert into public.equipment_unit_audit (
        unit_id, equipment_id, actor_id, action, old_values, new_values
      )
      values (
        v_unit_id, v_equipment_id, v_actor, 'status_changed',
        jsonb_build_object('status', 'available'),
        jsonb_build_object('status', 'lost', 'report_id', p_report_id)
      );
    end if;
  end if;

  update public.damage_loss_reports
  set resolution_status = p_resolution_status,
      resolution_notes = nullif(trim(p_resolution_notes), ''),
      is_recovered = case when v_report_type = 'loss' then p_is_recovered else false end,
      quantity_deducted = v_new_deducted,
      resolved_by = case when p_resolution_status in ('resolved', 'waived') then v_actor else null end,
      resolved_at = case when p_resolution_status in ('resolved', 'waived') then now() else null end,
      updated_at = now()
  where report_id = p_report_id;

  if v_report_type = 'damage' then
    if not v_new_deducted and v_old_deducted then v_changed_quantity := v_quantity;
    elsif v_new_deducted and not v_old_deducted then v_changed_quantity := -v_quantity;
    end if;
  elsif p_is_recovered and not v_old_recovered then
    v_changed_quantity := v_quantity;
  elsif not p_is_recovered and v_old_recovered then
    v_changed_quantity := -v_quantity;
  end if;

  update public.equipment e
  set condition_status = case
        when exists (
          select 1 from public.damage_loss_reports d
          join public.borrowing_items bi using (borrowing_item_id)
          where bi.equipment_id = e.equipment_id and d.report_type = 'damage'
            and d.resolution_status in ('open', 'under_review', 'waived')
        ) then 'damaged'
        when v_report_type = 'damage' and p_resolution_status = 'resolved' then 'good'
        else e.condition_status
      end,
      availability_status = case
        when e.availability_status = 'retired' then 'retired'
        when e.availability_status = 'maintenance' and not exists (
          select 1 from public.damage_loss_reports d
          join public.borrowing_items bi using (borrowing_item_id)
          where bi.equipment_id = e.equipment_id
        ) then 'maintenance'
        when e.tracking_mode = 'unit' and exists (
          select 1 from public.equipment_units u
          where u.equipment_id = e.equipment_id and u.status = 'available'
            and not exists (
              select 1 from public.damage_loss_reports d
              join public.borrowing_items bi using (borrowing_item_id)
              where bi.unit_id = u.unit_id and d.resolution_status in ('open', 'under_review', 'waived')
            )
        ) then 'available'
        when e.tracking_mode = 'unit' and exists (
          select 1 from public.equipment_units u
          where u.equipment_id = e.equipment_id and u.status = 'borrowed'
        ) then 'borrowed'
        when e.tracking_mode = 'unit' then 'maintenance'
        when e.quantity - e.out_of_service_quantity - coalesce((
          select sum(d.quantity_affected) from public.damage_loss_reports d
          join public.borrowing_items bi using (borrowing_item_id)
          where bi.equipment_id = e.equipment_id and d.quantity_deducted
        ), 0) <= 0 then 'maintenance'
        when coalesce((
          select sum(greatest(0, bi.quantity - coalesce((
            select sum(d.quantity_affected) from public.damage_loss_reports d
            where d.borrowing_item_id = bi.borrowing_item_id and d.quantity_deducted
          ), 0)))
          from public.borrowing_items bi
          join public.borrowings b using (borrowing_id)
          where bi.equipment_id = e.equipment_id and b.transaction_status in ('approved', 'released')
        ), 0) >= e.quantity - e.out_of_service_quantity - coalesce((
          select sum(d.quantity_affected) from public.damage_loss_reports d
          join public.borrowing_items bi using (borrowing_item_id)
          where bi.equipment_id = e.equipment_id and d.quantity_deducted
        ), 0) then 'borrowed'
        else 'available'
      end,
      updated_at = now()
  where e.equipment_id = v_equipment_id;

  select e.quantity, availability.available_quantity
    into v_total, v_available
  from public.equipment e
  join public.equipment_available_quantities() availability using (equipment_id)
  where e.equipment_id = v_equipment_id;

  if v_report_type = 'loss' and not p_is_recovered then
    v_message := format('Resolution saved. Lost quantity remains removed. Available: %s/%s.', v_available, v_total);
  elsif v_changed_quantity > 0 then
    v_message := format('Resolution saved. %s %s restored. Available: %s/%s.',
      v_changed_quantity, case when v_changed_quantity = 1 then 'unit' else 'units' end, v_available, v_total);
  elsif v_changed_quantity < 0 then
    v_message := format('Resolution saved. %s %s removed. Available: %s/%s.',
      abs(v_changed_quantity), case when abs(v_changed_quantity) = 1 then 'unit' else 'units' end, v_available, v_total);
  else
    v_message := format('Resolution saved. No quantity change. Available: %s/%s.', v_available, v_total);
  end if;
  return v_message;
end;
$$;
revoke all on function public.resolve_damage_loss_report(bigint, text, text, boolean) from public, anon;
grant execute on function public.resolve_damage_loss_report(bigint, text, text, boolean) to authenticated;

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
  v_out_of_service integer;
  v_status text;
  v_reported_quantity integer;
  v_capacity integer;
begin
  if (select auth.uid()) is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role in ('admin', 'property_custodian', 'staff')
    ) then
    return false;
  end if;
  if p_requested_quantity is null or p_requested_quantity < 1
    or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    return false;
  end if;

  select e.tracking_mode, e.quantity, e.out_of_service_quantity, e.availability_status
    into v_mode, v_quantity, v_out_of_service, v_status
  from public.equipment e
  where e.equipment_id = p_equipment_id and e.deleted_at is null;
  if not found or v_status = 'retired' then return false; end if;

  if v_mode = 'unit' then
    select count(*)::integer into v_capacity
    from public.equipment_units u
    where u.equipment_id = p_equipment_id
      and u.status in ('available', 'borrowed')
      and (u.status <> 'available' or not exists (
        select 1
        from public.damage_loss_reports d
        join public.borrowing_items bi using (borrowing_item_id)
        where bi.unit_id = u.unit_id
          and d.resolution_status in ('open', 'under_review', 'waived')
      ));
  else
    select coalesce(sum(d.quantity_affected), 0)::integer into v_reported_quantity
    from public.damage_loss_reports d
    join public.borrowing_items bi using (borrowing_item_id)
    where bi.equipment_id = p_equipment_id and d.quantity_deducted;
    v_capacity := greatest(0, v_quantity - v_out_of_service - v_reported_quantity);
    if v_status = 'maintenance' and v_reported_quantity = 0 then
      return false;
    end if;
  end if;
  if v_capacity < p_requested_quantity then return false; end if;

  return not exists (
    with occupied as (
      select b.request_date::date as start_date,
        case when b.expected_return_date::date < current_date then 'infinity'::date
          else b.expected_return_date::date end as end_date,
        case when v_mode = 'unit' then bi.quantity
          else greatest(0, bi.quantity - coalesce(report_effect.quantity, 0)) end as quantity
      from public.borrowings b
      join public.borrowing_items bi using (borrowing_id)
      left join lateral (
        select coalesce(sum(d.quantity_affected), 0)::integer as quantity
        from public.damage_loss_reports d
        where d.borrowing_item_id = bi.borrowing_item_id and d.quantity_deducted
      ) report_effect on true
      where bi.equipment_id = p_equipment_id
        and b.transaction_status in ('approved', 'released')
        and (v_mode <> 'unit' or bi.item_status in ('approved', 'released'))
        and (p_exclude_borrowing_id is null or b.borrowing_id <> p_exclude_borrowing_id)
      union all
      select r.start_date, r.end_date, r.quantity
      from public.reservations r
      where r.equipment_id = p_equipment_id
        and r.status = 'approved'
        and (p_exclude_reservation_id is null or r.reservation_id <> p_exclude_reservation_id)
    ),
    candidate_dates as (
      select p_start_date as occupied_on
      union
      select o.start_date from occupied o
      where o.start_date > p_start_date and o.start_date <= p_end_date
    )
    select 1 from candidate_dates d
    where (
      select coalesce(sum(o.quantity), 0)
      from occupied o
      where o.start_date <= d.occupied_on and o.end_date >= d.occupied_on
    ) + p_requested_quantity > v_capacity
  );
end;
$$;
revoke all on function public.equipment_period_has_capacity(bigint, date, date, integer, bigint, bigint)
  from public, anon, authenticated;

create or replace function public.equipment_period_has_approval_capacity(
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
begin
  if (select auth.uid()) is null or not public.is_equipment_manager_user() then
    return false;
  end if;
  return public.equipment_period_has_capacity(
    p_equipment_id, p_start_date, p_end_date, p_requested_quantity,
    p_exclude_borrowing_id, p_exclude_reservation_id
  );
end;
$$;
revoke all on function public.equipment_period_has_approval_capacity(bigint, date, date, integer, bigint, bigint)
  from public, anon, authenticated;

create or replace function public.equipment_available_quantities()
returns table (equipment_id bigint, available_quantity integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_verified_active_user()
    or not exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role in ('staff', 'admin', 'property_custodian')
    ) then
    raise exception 'Sign in with an active account to view availability.';
  end if;

  return query
  select e.equipment_id,
    case
      when e.availability_status = 'retired' then 0
      when e.availability_status = 'maintenance' and coalesce(reports.amount, 0) = 0 then 0
      when e.tracking_mode = 'unit' then greatest(0, coalesce(units.available, 0) - coalesce(occupied.amount, 0))
      else greatest(0, e.quantity - e.out_of_service_quantity
        - coalesce(reports.amount, 0) - coalesce(occupied.amount, 0))
    end::integer
  from public.equipment e
  left join lateral (
    select count(*)::integer as available
    from public.equipment_units u
    where u.equipment_id = e.equipment_id and u.status = 'available'
      and not exists (
        select 1
        from public.damage_loss_reports d
        join public.borrowing_items bi using (borrowing_item_id)
        where bi.unit_id = u.unit_id
          and d.resolution_status in ('open', 'under_review', 'waived')
      )
  ) units on true
  left join lateral (
    select coalesce(sum(active.amount), 0)::integer as amount
    from (
      select case when e.tracking_mode = 'unit' then bi.quantity
        else greatest(0, bi.quantity - coalesce(report_effect.quantity, 0)) end as amount
      from public.borrowing_items bi
      join public.borrowings b using (borrowing_id)
      left join lateral (
        select coalesce(sum(d.quantity_affected), 0)::integer as quantity
        from public.damage_loss_reports d
        where d.borrowing_item_id = bi.borrowing_item_id and d.quantity_deducted
      ) report_effect on true
      where bi.equipment_id = e.equipment_id
        and b.transaction_status in ('approved', 'released')
        and b.request_date::date <= current_date
        and (b.transaction_status = 'released' or b.expected_return_date::date >= current_date)
        and (e.tracking_mode <> 'unit' or b.transaction_status = 'approved')
      union all
      select r.quantity
      from public.reservations r
      where r.equipment_id = e.equipment_id
        and r.status = 'approved'
        and r.start_date <= current_date and r.end_date >= current_date
    ) active
  ) occupied on true
  left join lateral (
    select coalesce(sum(d.quantity_affected), 0)::integer as amount
    from public.damage_loss_reports d
    join public.borrowing_items bi using (borrowing_item_id)
    where bi.equipment_id = e.equipment_id and d.quantity_deducted
  ) reports on true
  where e.deleted_at is null;
end;
$$;
revoke all on function public.equipment_available_quantities() from public, anon;
grant execute on function public.equipment_available_quantities() to authenticated;

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
  if not exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role in ('staff', 'admin', 'property_custodian')
  ) then
    raise exception 'This account cannot search equipment.';
  end if;

  return query
  select e.equipment_id, e.asset_code::text, e.equipment_name::text, e.category_id,
    c.category_name::text, e.quantity, e.out_of_service_quantity, e.tracking_mode,
    case
      when e.availability_status = 'retired' then 'retired'
      when availability.available_quantity <= 0 then 'maintenance'
      when e.availability_status = 'borrowed' then 'borrowed'
      else 'available'
    end::text,
    availability.available_quantity,
    e.image_url::text, e.storage_location::text, e.brand::text, e.model::text,
    e.description::text, count(*) over ()
  from public.equipment e
  join public.categories c using (category_id)
  join public.equipment_available_quantities() availability using (equipment_id)
  where e.deleted_at is null
    and (p_category_id is null or e.category_id = p_category_id)
    and (nullif(trim(p_search), '') is null
      or lower(e.equipment_name) like lower(trim(p_search)) || '%'
      or lower(e.asset_code) like lower(trim(p_search)) || '%'
      or lower(coalesce(e.storage_location, '')) like lower(trim(p_search)) || '%')
    and (p_after_name is null or (e.equipment_name, e.equipment_id) > (p_after_name, p_after_id))
  order by e.equipment_name, e.equipment_id
  limit 20;
end;
$$;
revoke all on function public.search_equipment_page(text, bigint, text, bigint) from public, anon;
grant execute on function public.search_equipment_page(text, bigint, text, bigint) to authenticated;

alter function public.release_equipment_borrowing(bigint, text, text, text)
  rename to release_equipment_borrowing_base;
revoke all on function public.release_equipment_borrowing_base(bigint, text, text, text)
  from public, anon, authenticated;

create function public.release_equipment_borrowing(
  p_borrowing_id bigint,
  p_condition text,
  p_photo_path text,
  p_condition_notes text,
  p_affected_quantities jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_first_report_id bigint;
  v_report record;
  v_quantity integer;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can release equipment.';
  end if;
  if p_affected_quantities is not null and jsonb_typeof(p_affected_quantities) <> 'object' then
    raise exception 'Affected quantities must be provided as a borrowing-item map.';
  end if;
  select coalesce(max(report_id), 0) into v_first_report_id
  from public.damage_loss_reports;

  perform public.release_equipment_borrowing_base(
    p_borrowing_id, p_condition, p_photo_path, p_condition_notes
  );

  if p_condition = 'damaged' then
    for v_report in
      select d.report_id, d.borrowing_item_id, bi.quantity
      from public.damage_loss_reports d
      join public.borrowing_items bi using (borrowing_item_id)
      where d.report_id > v_first_report_id and bi.borrowing_id = p_borrowing_id
      order by d.report_id
    loop
      if p_affected_quantities ? v_report.borrowing_item_id::text then
        if (p_affected_quantities ->> v_report.borrowing_item_id::text) !~ '^[0-9]+$' then
          raise exception 'Affected quantity must be a whole number.';
        end if;
        v_quantity := (p_affected_quantities ->> v_report.borrowing_item_id::text)::integer;
      else
        v_quantity := 1;
      end if;
      if v_quantity < 1 or v_quantity > v_report.quantity then
        raise exception 'Affected quantity must be between 1 and the borrowed quantity.';
      end if;
      update public.damage_loss_reports
      set quantity_affected = v_quantity, quantity_deducted = true, updated_at = now()
      where report_id = v_report.report_id;
    end loop;
  end if;
end;
$$;
revoke all on function public.release_equipment_borrowing(bigint, text, text, text, jsonb)
  from public, anon;
grant execute on function public.release_equipment_borrowing(bigint, text, text, text, jsonb)
  to authenticated;

create or replace function public.release_equipment_borrowing(
  p_borrowing_id bigint,
  p_condition text,
  p_photo_path text default null,
  p_condition_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can release equipment.';
  end if;
  perform public.release_equipment_borrowing(
    p_borrowing_id, p_condition, p_photo_path, p_condition_notes, null
  );
end;
$$;
revoke all on function public.release_equipment_borrowing(bigint, text, text, text)
  from public, anon;
grant execute on function public.release_equipment_borrowing(bigint, text, text, text)
  to authenticated;

create or replace function public.complete_equipment_return(
  p_borrowing_id bigint,
  p_condition text,
  p_photo_path text default null,
  p_condition_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can receive returned equipment.';
  end if;
  perform public.complete_equipment_return(
    p_borrowing_id, p_condition, p_photo_path, p_condition_notes, null
  );
end;
$$;
revoke all on function public.complete_equipment_return(bigint, text, text, text)
  from public, anon;
grant execute on function public.complete_equipment_return(bigint, text, text, text)
  to authenticated;

create function public.complete_equipment_return(
  p_borrowing_id bigint,
  p_condition text,
  p_photo_path text,
  p_condition_notes text,
  p_affected_quantities jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_item record;
  v_equipment_id bigint;
  v_quantity integer;
  v_report_type text;
begin
  if v_actor is null or not public.is_equipment_manager_user() then
    raise exception 'Only administrators and property custodians can receive returned equipment.';
  end if;
  if p_condition is null or p_condition not in ('good', 'fair', 'damaged', 'lost') then
    raise exception 'Choose a valid condition at return.';
  end if;
  if not public.workflow_photo_path_is_valid(p_photo_path, v_actor) then
    raise exception 'The return photo path is invalid.';
  end if;
  if p_condition in ('damaged', 'lost') and nullif(trim(p_condition_notes), '') is null then
    raise exception 'Add a brief damage or loss description before receiving the item.';
  end if;
  if p_affected_quantities is not null and jsonb_typeof(p_affected_quantities) <> 'object' then
    raise exception 'Affected quantities must be provided as a borrowing-item map.';
  end if;

  perform e.equipment_id
  from public.equipment e
  join public.borrowing_items bi on bi.equipment_id = e.equipment_id
  where bi.borrowing_id = p_borrowing_id
  order by e.equipment_id
  for update of e;
  if not found then raise exception 'The borrowing equipment could not be found.'; end if;
  perform 1 from public.borrowings b
  where b.borrowing_id = p_borrowing_id and b.transaction_status = 'released'
  for update;
  if not found then raise exception 'Only released borrowings can be returned.'; end if;
  if exists (
    select 1 from public.borrowing_items bi
    join public.equipment e using (equipment_id)
    where bi.borrowing_id = p_borrowing_id
      and (bi.item_status <> 'released' or e.tracking_mode = 'unit')
  ) then
    raise exception 'Return unit-tracked equipment through the unit return workflow.';
  end if;

  update public.borrowing_items
  set item_status = 'returned', received_by = v_actor, returned_at = now(),
      condition_at_return = p_condition, return_photo_path = p_photo_path, is_overdue = false
  where borrowing_id = p_borrowing_id;
  update public.borrowings
  set transaction_status = 'returned', updated_at = now()
  where borrowing_id = p_borrowing_id;
  update public.damage_loss_reports d
  set quantity_deducted = true, updated_at = now()
  from public.borrowing_items bi
  where bi.borrowing_id = p_borrowing_id
    and d.borrowing_item_id = bi.borrowing_item_id
    and d.resolution_status in ('open', 'under_review', 'waived')
    and not d.quantity_deducted;

  if p_condition in ('damaged', 'lost') then
    v_report_type := case when p_condition = 'lost' then 'loss' else 'damage' end;
    for v_item in
      select bi.borrowing_item_id, bi.quantity
      from public.borrowing_items bi
      where bi.borrowing_id = p_borrowing_id
      order by bi.borrowing_item_id
    loop
      if p_affected_quantities ? v_item.borrowing_item_id::text then
        if (p_affected_quantities ->> v_item.borrowing_item_id::text) !~ '^[0-9]+$' then
          raise exception 'Affected quantity must be a whole number.';
        end if;
        v_quantity := (p_affected_quantities ->> v_item.borrowing_item_id::text)::integer;
      else
        v_quantity := 1;
      end if;
      if v_quantity < 1 or v_quantity > v_item.quantity then
        raise exception 'Affected quantity must be between 1 and the borrowed quantity.';
      end if;
      if exists (
        select 1 from public.damage_loss_reports d
        where d.borrowing_item_id = v_item.borrowing_item_id
          and d.report_type = v_report_type
          and d.resolution_status in ('open', 'under_review', 'waived')
      ) then
        update public.damage_loss_reports
        set quantity_affected = v_quantity, quantity_deducted = true,
            description = trim(p_condition_notes), photo_path = p_photo_path, updated_at = now()
        where borrowing_item_id = v_item.borrowing_item_id
          and report_type = v_report_type
          and resolution_status in ('open', 'under_review', 'waived');
      else
        insert into public.damage_loss_reports (
          borrowing_item_id, reporter_id, report_type, description, photo_path,
          quantity_affected, quantity_deducted
        )
        values (
          v_item.borrowing_item_id, v_actor, v_report_type, trim(p_condition_notes), p_photo_path,
          v_quantity, true
        );
      end if;
    end loop;
  end if;

  update public.return_requests
  set status = 'completed', completed_at = now()
  where borrowing_id = p_borrowing_id and status = 'pending';

  for v_equipment_id in
    select distinct bi.equipment_id
    from public.borrowing_items bi
    where bi.borrowing_id = p_borrowing_id
    order by bi.equipment_id
  loop
    update public.equipment e
    set condition_status = case
          when exists (
            select 1 from public.damage_loss_reports d
            join public.borrowing_items bi using (borrowing_item_id)
            where bi.equipment_id = e.equipment_id and d.report_type = 'damage'
              and d.resolution_status in ('open', 'under_review', 'waived')
          ) then 'damaged'
          when p_condition = 'damaged' then 'good'
          else e.condition_status
        end,
        availability_status = case
          when e.availability_status = 'retired'
            and (e.tracking_mode = 'unit' or not exists (
              select 1 from public.damage_loss_reports d
              join public.borrowing_items bi using (borrowing_item_id)
              where bi.equipment_id = e.equipment_id and d.report_type = 'loss'
            )) then 'retired'
          when e.tracking_mode = 'quantity' and e.availability_status = 'maintenance'
            and not exists (
              select 1 from public.damage_loss_reports d
              join public.borrowing_items bi using (borrowing_item_id)
              where bi.equipment_id = e.equipment_id
            ) then 'maintenance'
          when e.quantity - e.out_of_service_quantity - coalesce((
            select sum(d.quantity_affected) from public.damage_loss_reports d
            join public.borrowing_items bi using (borrowing_item_id)
            where bi.equipment_id = e.equipment_id and d.quantity_deducted
          ), 0) <= 0 then 'maintenance'
          when coalesce((
            select sum(greatest(0, bi.quantity - coalesce((
              select sum(d.quantity_affected) from public.damage_loss_reports d
              where d.borrowing_item_id = bi.borrowing_item_id and d.quantity_deducted
            ), 0)))
            from public.borrowing_items bi
            join public.borrowings b using (borrowing_id)
            where bi.equipment_id = e.equipment_id and b.transaction_status in ('approved', 'released')
              and b.request_date::date <= current_date
              and (b.transaction_status = 'released' or b.expected_return_date::date >= current_date)
          ), 0) >= e.quantity - e.out_of_service_quantity - coalesce((
            select sum(d.quantity_affected) from public.damage_loss_reports d
            join public.borrowing_items bi using (borrowing_item_id)
            where bi.equipment_id = e.equipment_id and d.quantity_deducted
          ), 0) then 'borrowed'
          else 'available'
        end,
        updated_at = now()
    where e.equipment_id = v_equipment_id;
  end loop;
end;
$$;
revoke all on function public.complete_equipment_return(bigint, text, text, text, jsonb)
  from public, anon;
grant execute on function public.complete_equipment_return(bigint, text, text, text, jsonb)
  to authenticated;

update public.equipment e
set availability_status = case
  when e.availability_status = 'retired' then 'retired'
  when e.tracking_mode = 'unit' and exists (
    select 1 from public.equipment_units u
    where u.equipment_id = e.equipment_id and u.status = 'available'
      and not exists (
        select 1 from public.damage_loss_reports d
        join public.borrowing_items bi using (borrowing_item_id)
        where bi.unit_id = u.unit_id and d.resolution_status in ('open', 'under_review', 'waived')
      )
  ) then 'available'
  when e.tracking_mode = 'unit' and exists (
    select 1 from public.equipment_units u
    where u.equipment_id = e.equipment_id and u.status = 'borrowed'
  ) then 'borrowed'
  when e.tracking_mode = 'unit' then 'maintenance'
  when e.quantity - e.out_of_service_quantity - coalesce((
    select sum(d.quantity_affected) from public.damage_loss_reports d
    join public.borrowing_items bi using (borrowing_item_id)
    where bi.equipment_id = e.equipment_id and d.quantity_deducted
  ), 0) <= 0 then 'maintenance'
  when coalesce((
    select sum(greatest(0, bi.quantity - coalesce((
      select sum(d.quantity_affected) from public.damage_loss_reports d
      where d.borrowing_item_id = bi.borrowing_item_id and d.quantity_deducted
    ), 0)))
    from public.borrowing_items bi
    join public.borrowings b using (borrowing_id)
    where bi.equipment_id = e.equipment_id and b.transaction_status in ('approved', 'released')
  ), 0) >= e.quantity - e.out_of_service_quantity - coalesce((
    select sum(d.quantity_affected) from public.damage_loss_reports d
    join public.borrowing_items bi using (borrowing_item_id)
    where bi.equipment_id = e.equipment_id and d.quantity_deducted
  ), 0) then 'borrowed'
  else 'available'
end,
condition_status = case
  when exists (
    select 1 from public.damage_loss_reports d
    join public.borrowing_items bi using (borrowing_item_id)
    where bi.equipment_id = e.equipment_id and d.report_type = 'damage'
      and d.resolution_status in ('open', 'under_review', 'waived')
  ) then 'damaged'
  else e.condition_status
end,
updated_at = now()
where e.deleted_at is null;

commit;

