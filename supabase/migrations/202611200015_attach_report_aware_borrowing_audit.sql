begin;

drop trigger if exists audit_borrowing_status_change on public.borrowings;
drop trigger if exists audit_borrowing_item_status_change on public.borrowing_items;

create trigger audit_borrowing_status_change
after update of transaction_status on public.borrowings
for each row execute function public.audit_borrowing_workflow_status();

create trigger audit_borrowing_item_status_change
after update of item_status, is_overdue on public.borrowing_items
for each row execute function public.audit_borrowing_workflow_status();

commit;
