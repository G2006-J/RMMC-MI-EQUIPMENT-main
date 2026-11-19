begin;

create or replace function public.notify_borrowing_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrower_user uuid;
  v_reported_by_actor boolean := false;
  v_title text;
  v_message text;
  v_type text;
begin
  if v_actor is not null then
    if tg_op = 'INSERT' then
      if not public.is_verified_active_user()
        or not exists (
          select 1 from public.profiles p
          where p.id = v_actor and p.role = 'staff' and p.account_status = 'active'
        ) then
        raise exception 'Only an active borrower can submit a borrowing request.';
      end if;
    elsif not public.is_equipment_manager_user() then
      select br.user_id into v_borrower_user
      from public.borrowings b
      join public.borrowers br using (borrower_id)
      where b.borrowing_id = new.borrowing_id;

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
        or v_borrower_user is distinct from v_actor
        or old.transaction_status <> 'released'
        or new.transaction_status <> 'returned'
        or not v_reported_by_actor then
        raise exception 'Only equipment managers can change borrowing status unless the owning borrower submitted a damage or loss report.';
      end if;
    end if;
  elsif session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified actor is required to notify about a borrowing change.';
  end if;

  select br.user_id into v_borrower_user
  from public.borrowers br
  where br.borrower_id = new.borrower_id;
  if v_borrower_user is null then
    raise exception 'The borrowing request has no linked account.';
  end if;

  if tg_op = 'INSERT' then
    if new.transaction_status <> 'requested' then
      return new;
    end if;
    insert into public.notifications (user_id, borrowing_id, title, message, notification_type)
    select p.id, new.borrowing_id, 'Borrowing request waiting for review',
      'A new equipment borrowing request is waiting for staff review.', 'request_pending'
    from public.profiles p
    where p.role in ('admin', 'property_custodian') and p.account_status = 'active';
    return new;
  end if;

  if new.transaction_status is not distinct from old.transaction_status then
    return new;
  end if;
  case new.transaction_status
    when 'approved' then
      v_type := 'request_approved';
      v_title := 'Borrowing request approved';
      v_message := 'Your equipment borrowing request was approved.';
    when 'rejected' then
      v_type := 'request_declined';
      v_title := 'Borrowing request declined';
      v_message := 'Your request was declined. Reason: ' || coalesce(nullif(trim(new.decline_reason), ''), 'No reason provided.');
    when 'released' then
      v_type := 'item_released';
      v_title := 'Equipment released';
      v_message := 'The approved equipment has been released to you.';
    when 'returned' then
      v_type := 'return_confirmed';
      v_title := 'Equipment return confirmed';
      v_message := 'Your equipment borrowing was completed after a damage or loss report.';
    else
      return new;
  end case;
  insert into public.notifications (user_id, borrowing_id, title, message, notification_type)
  values (v_borrower_user, new.borrowing_id, v_title, v_message, v_type);
  return new;
end;
$$;
revoke all on function public.notify_borrowing_event() from public, anon, authenticated;

create or replace function public.notify_borrowing_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrower_user uuid;
  v_reported_by_actor boolean;
begin
  if tg_op <> 'UPDATE'
    or new.transaction_status is not distinct from old.transaction_status then
    return new;
  end if;

  if v_actor is not null and not public.is_equipment_manager_user() then
    select br.user_id into v_borrower_user
    from public.borrowings b
    join public.borrowers br using (borrower_id)
    where b.borrowing_id = new.borrowing_id;

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
      or v_borrower_user is distinct from v_actor
      or old.transaction_status <> 'released'
      or new.transaction_status <> 'returned'
      or not v_reported_by_actor then
      raise exception 'Only equipment managers can approve, decline, release, or confirm returns.';
    end if;
  elsif v_actor is null and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'A verified actor is required to change borrowing status.';
  end if;

  return new;
end;
$$;
revoke all on function public.notify_borrowing_status_change() from public, anon, authenticated;

drop trigger if exists notify_borrowing_status_changed on public.borrowings;
create trigger notify_borrowing_status_changed
after update of transaction_status on public.borrowings
for each row execute function public.notify_borrowing_event();

commit;
