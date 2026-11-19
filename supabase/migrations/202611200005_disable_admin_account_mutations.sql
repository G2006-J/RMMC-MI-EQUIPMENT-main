begin;

revoke execute on function public.admin_deactivate_borrower_account(uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.admin_anonymize_inactive_borrower(uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.admin_update_profile_access(uuid, text, text)
  from public, anon, authenticated, service_role;

revoke insert on public.phase7_audit_log from service_role;

do $$
declare
  v_audit_sequence text := pg_get_serial_sequence('public.phase7_audit_log', 'audit_id');
begin
  if v_audit_sequence is not null then
    execute format('revoke usage, select on sequence %s from service_role', v_audit_sequence);
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
