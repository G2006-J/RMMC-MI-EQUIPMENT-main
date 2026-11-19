begin;

do $$
declare
  v_ict_category_id public.categories.category_id%type;
  v_category record;
begin
  select category_id into v_ict_category_id
  from public.categories
  where category_name = 'ICT Equipment';

  if v_ict_category_id is null then
    select category_id into v_ict_category_id
    from public.categories
    where lower(trim(category_name)) in (
      'ict equipment',
      'computer and laptops',
      'computers and laptops'
    )
    order by case
      when lower(trim(category_name)) = 'computer and laptops' then 0
      when lower(trim(category_name)) = 'computers and laptops' then 1
      else 2
    end, category_id
    limit 1;

    if v_ict_category_id is null then
      insert into public.categories (category_name)
      values ('ICT Equipment')
      returning category_id into v_ict_category_id;
    else
      update public.categories
      set category_name = 'ICT Equipment'
      where category_id = v_ict_category_id;
    end if;
  end if;

  for v_category in
    select category_id
    from public.categories
    where lower(trim(category_name)) in (
      'ict equipment',
      'computer and laptops',
      'computers and laptops'
    )
      and category_id <> v_ict_category_id
  loop
    update public.equipment
    set category_id = v_ict_category_id
    where category_id = v_category.category_id;

    delete from public.categories
    where category_id = v_category.category_id;
  end loop;
end;
$$;

commit;
