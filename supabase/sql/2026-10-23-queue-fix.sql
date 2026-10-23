create or replace function public.rb_billing_enqueue() returns trigger language plpgsql security definer set search_path=public as $$
declare v_order bigint;
begin
  if tg_table_name='narocila' then v_order:=new.id;else v_order:=new.narocilo_id;end if;
  if v_order is not null then insert into public.rb_billing_queue(narocilo_id) values(v_order) on conflict(narocilo_id) do update set updated_at=now(); end if;
  return new;
end$$;
