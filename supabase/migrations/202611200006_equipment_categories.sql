begin;

do $$
declare
  v_old_category record;
  v_ict_category_id bigint;
begin
  select category_id into v_ict_category_id
  from public.categories
  where category_name = 'ICT Equipment';

  for v_old_category in
    select category_id
    from public.categories
    where lower(trim(category_name)) = lower('Computer and Laptops')
  loop
    if v_ict_category_id is null then
      update public.categories
      set category_name = 'ICT Equipment'
      where category_id = v_old_category.category_id
      returning category_id into v_ict_category_id;
    else
      update public.equipment
      set category_id = v_ict_category_id
      where category_id = v_old_category.category_id;

      delete from public.categories
      where category_id = v_old_category.category_id;
    end if;
  end loop;
end;
$$;

insert into public.categories (category_name)
values ('ICT Equipment'), ('Sport Equipments'), ('Furniture and Fixtures')
on conflict (category_name) do nothing;

commit;
