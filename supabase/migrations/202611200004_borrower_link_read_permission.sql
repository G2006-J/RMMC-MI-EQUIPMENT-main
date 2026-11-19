begin;

grant select (user_id) on public.borrowers to authenticated;

commit;
