begin;

create or replace function public.audit_borrowing_workflow_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_borrowing_id bigint;
  v_borrowing_item_id bigint;
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
    v_borrowing_item_id := new.borrowing_item_id;
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
    v_borrowing_id, v_borrowing_item_id, v_entity, v_event, v_actor, v_before, v_after
  );
  return new;
end;
$$;
revoke all on function public.audit_borrowing_workflow_status() from public, anon, authenticated;

commit;
