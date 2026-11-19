begin;

drop policy if exists "administrators manage equipment" on public.equipment;
drop policy if exists "equipment managers manage equipment" on public.equipment;
drop policy if exists "Managers can manage equipment" on public.equipment;
create policy "equipment managers insert equipment"
  on public.equipment for insert to authenticated
  with check (public.is_equipment_manager_user());
create policy "equipment managers update equipment"
  on public.equipment for update to authenticated
  using (public.is_equipment_manager_user())
  with check (public.is_equipment_manager_user());

grant insert, update on public.equipment to authenticated;
grant usage, select on sequence public.equipment_equipment_id_seq to authenticated;

drop policy if exists "admins upload equipment images" on storage.objects;
drop policy if exists "admins update equipment images" on storage.objects;
drop policy if exists "admins delete equipment images" on storage.objects;
drop policy if exists "equipment managers upload images" on storage.objects;
drop policy if exists "equipment managers update images" on storage.objects;
drop policy if exists "equipment managers delete images" on storage.objects;
create policy "equipment managers upload images"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'equipment-images' and public.is_equipment_manager_user());
create policy "equipment managers update images"
  on storage.objects for update to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_manager_user())
  with check (bucket_id = 'equipment-images' and public.is_equipment_manager_user());
create policy "equipment managers delete images"
  on storage.objects for delete to authenticated
  using (bucket_id = 'equipment-images' and public.is_equipment_manager_user());

drop policy if exists "administrators delete feedback threads" on public.feedback_threads;
create policy "equipment managers delete feedback threads"
  on public.feedback_threads for delete to authenticated
  using (public.is_equipment_manager_user());
grant delete on public.feedback_threads to authenticated;

drop policy if exists "administrators delete feedback replies" on public.feedback_replies;
create policy "equipment managers delete feedback replies"
  on public.feedback_replies for delete to authenticated
  using (public.is_equipment_manager_user());
grant delete on public.feedback_replies to authenticated;

create or replace function public.phase7_audit_feedback_reply_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null then
    if session_user not in ('postgres', 'supabase_admin') then
      raise exception 'An active equipment manager is required to delete feedback replies.';
    end if;
  elsif not public.is_equipment_manager_user() then
    raise exception 'Only active equipment managers can delete feedback replies.';
  end if;

  begin
    insert into public.phase7_audit_log (
      actor_id, source, event_type, entity_type, entity_id, before_values, after_values
    )
    values (
      v_actor,
      case when v_actor is null then 'direct_sql' else 'trigger' end,
      'feedback_reply_deleted',
      'feedback_reply',
      old.id::text,
      jsonb_build_object('changed_fields', jsonb_build_array('deleted'), 'thread_id', old.thread_id),
      jsonb_build_object('changed_fields', jsonb_build_array('deleted'))
    );
  exception
    when check_violation or foreign_key_violation or not_null_violation or unique_violation or insufficient_privilege then
      raise warning 'Feedback reply audit insert failed for reply %.', old.id;
  end;
  return old;
end;
$$;
revoke all on function public.phase7_audit_feedback_reply_delete() from public, anon, authenticated;

drop policy if exists "read verified relevant return requests" on public.return_requests;
create policy "verified users and managers read return requests"
  on public.return_requests for select to authenticated
  using (
    public.is_verified_active_user()
    and (requested_by = (select auth.uid()) or public.is_equipment_manager_user())
  );

create or replace function public.require_borrower_return_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_old jsonb;
  v_new jsonb;
  v_old_status text;
  v_new_status text;
  v_borrowing_id bigint;
begin
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  v_borrowing_id := (v_new ->> 'borrowing_id')::bigint;

  if tg_table_name = 'borrowings' then
    v_old_status := v_old ->> 'transaction_status';
    v_new_status := v_new ->> 'transaction_status';
  elsif tg_table_name = 'borrowing_items' then
    v_old_status := v_old ->> 'item_status';
    v_new_status := v_new ->> 'item_status';
  else
    raise exception 'Return-request guard attached to an unsupported table.';
  end if;

  if v_new_status = 'returned' and v_old_status is distinct from 'returned' then
    if v_actor is null or not public.is_equipment_manager_user() then
      raise exception 'Only an active administrator or property custodian can record returned equipment.';
    end if;
    if not exists (
      select 1
      from public.return_requests rr
      join public.borrowings b using (borrowing_id)
      join public.borrowers br using (borrower_id)
      where rr.borrowing_id = v_borrowing_id
        and rr.status = 'pending'
        and rr.requested_by = br.user_id
    ) then
      raise exception 'The borrower must request a return before a manager can record it as returned.';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.require_borrower_return_request() from public, anon, authenticated;

drop trigger if exists require_borrower_return_request_on_borrowing on public.borrowings;
create trigger require_borrower_return_request_on_borrowing
  before update of transaction_status on public.borrowings
  for each row execute function public.require_borrower_return_request();

drop trigger if exists require_borrower_return_request_on_item on public.borrowing_items;
create trigger require_borrower_return_request_on_item
  before update of item_status on public.borrowing_items
  for each row execute function public.require_borrower_return_request();

notify pgrst, 'reload schema';
commit;
