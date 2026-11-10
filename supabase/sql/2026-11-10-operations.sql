begin;

-- Stari vstop ne sprejema spletnih zahtev brez potrjenega območja.
do $$begin
  if to_regprocedure('public.rb_create_transport_requests_core(bigint[],text,date,text,text,text)') is null then
    alter function public.rb_create_transport_requests(bigint[],text,date,text,text,text) rename to rb_create_transport_requests_core;
  end if;
end$$;
revoke all on function public.rb_create_transport_requests_core(bigint[],text,date,text,text,text) from public,anon,authenticated,service_role;

create or replace function public.rb_create_transport_requests(
 p_box_ids bigint[],p_action text,p_date date,p_time text,p_address text,p_note text default null,p_area text default null,p_place text default null
) returns table(zahteva_id bigint,narocilo_id bigint)
language plpgsql security definer set search_path=public as $$
begin
  if public.my_kupec_id() is null then raise exception 'Prijava je potrebna.';end if;
  if p_area is distinct from 'ljubljana' then
    raise exception 'Naročilo prevzemov preko spleta je možno samo po Ljubljani in okolici. Za naročila v ostalo Slovenijo in tujino nas kontaktirajte na 040 796 040 ali pošljite na email: info@rabimbox.si';
  end if;
  if nullif(btrim(p_address),'') is null or length(p_address)>400 or nullif(btrim(p_place),'') is null or length(p_place)>100
    or p_place ~ '[[:cntrl:]]' or p_address ~ '[[:cntrl:]]' then raise exception 'Vpišite veljaven naslov in kraj prevzema oziroma dostave.';end if;
  return query select * from public.rb_create_transport_requests_core(p_box_ids,p_action,p_date,p_time,btrim(p_address)||', '||btrim(p_place),p_note);
end;$$;
revoke all on function public.rb_create_transport_requests(bigint[],text,date,text,text,text,text,text) from public,anon;
grant execute on function public.rb_create_transport_requests(bigint[],text,date,text,text,text,text,text) to authenticated;

create or replace function public.sklad_stanje_narocil(p_ids bigint[])
returns table(narocilo_id bigint,aktivno boolean,st_boxov integer)
language plpgsql stable security definer set search_path=public as $$
begin
  if not public.is_staff() then raise exception 'Nimate dovoljenja.';end if;
  if coalesce(cardinality(p_ids),0)>5000 then raise exception 'Preveč naročil.';end if;
  return query select o.id,count(s.id)>0,count(s.id)::integer from public.narocila o
    left join public.narocnine n on n.narocilo_id=o.id left join public.skatle s on s.narocnina_id=n.id
    where o.id=any(p_ids) group by o.id;
end;$$;
revoke all on function public.sklad_stanje_narocil(bigint[]) from public,anon;
grant execute on function public.sklad_stanje_narocil(bigint[]) to authenticated;

-- Zaseben zaključek ne premika boxov; uporabi se šele, ko ni več dodeljenih.
create or replace function public.rb_close_empty_order(p_order bigint,p_notify boolean default true)
returns boolean language plpgsql security definer set search_path=public as $$
declare o public.narocila%rowtype;v_key text;
begin
  select * into o from public.narocila where id=p_order for update;
  if not found or o.status in('zakljuceno','preklicano') or not(o.placano or o.vir='rocno') then return false;end if;
  if not exists(select 1 from public.narocnine where narocilo_id=o.id)
    or exists(select 1 from public.skatle s join public.narocnine n on n.id=s.narocnina_id where n.narocilo_id=o.id) then return false;end if;
  update public.narocnine set status='zakljucena',auto_renew=false,cancel_requested_at=coalesce(cancel_requested_at,now()),
    naslednje_st_boxov=0,naslednja_cena=0,sprememba_od=null,updated_at=now() where narocilo_id=o.id;
  update public.narocila set status='zakljuceno' where id=o.id;
  insert into public.dnevnik_dejanj(akcija,opis,zaposleni_id)
    values('zakljucek','narocilo #'||o.id||': samodejno zaključeno po vračilu vseh boxov',auth.uid());
  if p_notify then
    select decrypted_secret into v_key from vault.decrypted_secrets where name='rabimbox_service_role' limit 1;
    if v_key is not null then
      perform net.http_post(url:='https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/poslji-obvestilo',
        headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key,'apikey',v_key),
        body:=jsonb_build_object('tip','zakljucek','narocilo_id',o.id));
    end if;
  end if;
  return true;
end;$$;
revoke all on function public.rb_close_empty_order(bigint,boolean) from public,anon,authenticated,service_role;

create or replace function public.rb_close_order_after_release()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_order bigint;
begin
  select narocilo_id into v_order from public.narocnine where id=old.narocnina_id;
  if v_order is not null then perform public.rb_close_empty_order(v_order,true);end if;
  return new;
end;$$;
revoke all on function public.rb_close_order_after_release() from public,anon,authenticated,service_role;

-- Odloženo preverjanje vidi končno stanje prevzema, preklica ali vračila v isti transakciji.
drop trigger if exists rb_close_order_without_boxes on public.skatle;
create constraint trigger rb_close_order_without_boxes after update on public.skatle
deferrable initially deferred for each row
when(old.narocnina_id is not null and old.narocnina_id is distinct from new.narocnina_id)
execute function public.rb_close_order_after_release();

-- Izplačil ni več mogoče sprožiti s starim brskalnikom ali starim finančnim vstopom.
create or replace function public.rb_box_return_quote(p_order bigint,p_boxes bigint[])
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin raise exception 'Vračilo denarja uredite ročno. V panelu vrnite boxe v zalogo, nato pošljite dobropis.';end;$$;
create or replace function public.rb_prepare_box_refund(p_order bigint,p_boxes bigint[],p_key uuid,p_expected integer,p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin raise exception 'Vračilo denarja uredite ročno. V panelu vrnite boxe v zalogo, nato pošljite dobropis.';end;$$;

-- Uskladitev obstoječih naročil brez boxov; ob migraciji ne pošilja poslovne pošte.
select public.rb_close_empty_order(o.id,false) from public.narocila o
where o.status not in('zakljuceno','preklicano') and (o.placano or o.vir='rocno')
  and exists(select 1 from public.narocnine n where n.narocilo_id=o.id)
  and not exists(select 1 from public.skatle s join public.narocnine n on n.id=s.narocnina_id where n.narocilo_id=o.id);

commit;
