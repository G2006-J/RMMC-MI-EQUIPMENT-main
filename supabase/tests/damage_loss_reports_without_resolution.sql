\set ON_ERROR_STOP on
begin;

do $$
declare
  v_result_type text;
begin
  if has_function_privilege(
    'authenticated',
    'public.resolve_damage_loss_report(bigint,text,text)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.resolve_damage_loss_report(bigint,text,text,boolean)',
    'execute'
  ) then
    raise exception 'Authenticated users can still resolve damage or loss reports.';
  end if;

  v_result_type := pg_get_function_result('public.list_damage_loss_reports()'::regprocedure);
  if v_result_type ilike '%resolution%' then
    raise exception 'Damage and loss report results still expose resolution fields.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.list_damage_loss_reports()',
    'execute'
  ) then
    raise exception 'Authenticated equipment managers cannot load damage and loss reports.';
  end if;
end;
$$;

rollback;

select 'PASS: damage/loss reports no longer expose resolution fields or allow report resolution.' as result;
