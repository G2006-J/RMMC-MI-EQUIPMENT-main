begin;

grant insert on public.phase7_audit_log to service_role;

do $$
declare
  v_audit_sequence text := pg_get_serial_sequence('public.phase7_audit_log', 'audit_id');
begin
  if v_audit_sequence is not null then
    execute format('grant usage, select on sequence %s to service_role', v_audit_sequence);
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
