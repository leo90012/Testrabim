-- Spletno narocilo nastane sele po potrjenem placilu.
-- Rocni vnos je locena pot, dovoljena le prijavljenemu osebju.
begin;
alter table public.narocila add column if not exists vir text not null default 'splet';
do $$ begin
  if not exists (select 1 from pg_constraint where conname='narocila_vir_check') then
    alter table public.narocila add constraint narocila_vir_check
      check (vir in ('splet', 'rocno'));
  end if;
end $$;
create unique index if not exists narocila_stevilka_unique
  on public.narocila(stevilka) where stevilka is not null;

-- Brskalnik ne sme vec neposredno ustvariti narocila in rezervirati boxov.
drop policy if exists narocila_insert on public.narocila;
revoke insert on public.narocila from anon, authenticated;

create table if not exists public.checkout_osnutki (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  order_data jsonb not null,
  stripe_session_id text unique,
  narocilo_id bigint unique references public.narocila(id),
  created_at timestamptz not null default now()
);
alter table public.checkout_osnutki enable row level security;
revoke all on public.checkout_osnutki from anon, authenticated;
grant all on public.checkout_osnutki to service_role;

-- Cenik mora biti enak znesku, ki ga zaracuna Stripe.
create or replace function public.rb_cena(p_tip text, p_boxov integer)
returns numeric language sql immutable set search_path = public as $$
  select case
    when coalesce(p_boxov,0) <= 0 then 0::numeric
    when lower(coalesce(p_tip,'')) like 'sklad%' then
      round(p_boxov * case when p_boxov <= 10 then 4.90
                           when p_boxov <= 25 then 4.20 else 3.80 end, 2)
    else case when p_boxov <= 20 then 69.00
              when p_boxov <= 40 then 109.00
              when p_boxov <= 60 then 149.00
              when p_boxov <= 80 then 189.00
              else 0::numeric end
  end;
$$;
update public.narocnine n set cena_mesecna=public.rb_cena(n.tip,n.st_boxov)
where n.cena_mesecna is null and n.status='aktivna'
  and exists (select 1 from public.narocila o where o.id=n.narocilo_id and o.placano=true);

-- Pri spletnem narocilu sprozilec zdaj vidi samo placane zapise.
create or replace function public.narocilo_dodeli_skatle()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_n int; v_sub bigint;
begin
  if new.placano is distinct from true and new.vir <> 'rocno' then return new; end if;
  v_n := greatest(coalesce(new.st_boxov,0),0);
  if new.kupec_id is null or v_n = 0 then return new; end if;
  insert into public.narocnine
    (kupec_id,narocilo_id,tip,st_boxov,cena_mesecna,datum_od,status)
  values
    (new.kupec_id,new.id,new.tip,v_n,public.rb_cena(new.tip,v_n),
     coalesce(new.datum_dostave,current_date),'aktivna')
  returning id into v_sub;
  with pick as (
    select id from public.skatle
    where status='na_zalogi' and kupec_id is null
    order by id limit v_n for update skip locked
  )
  update public.skatle s
  set kupec_id=new.kupec_id,narocnina_id=v_sub,status='rezervirana',
      tip_storitve=new.tip,updated_at=now()
  from pick where s.id=pick.id;
  return new;
end;
$$;

-- Atomaren zakljucek placila; oba Stripe klica uporabita isto funkcijo.
create or replace function public.rb_finalize_paid_checkout(
  p_draft_id uuid, p_session_id text, p_amount_cents integer
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_draft public.checkout_osnutki%rowtype;
        v_order jsonb; v_n public.narocila%rowtype;
        v_total numeric; v_base numeric; v_vat numeric;
        v_customer bigint;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'Ni dovoljeno.';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Neveljaven placani znesek.';
  end if;
  select * into v_draft from public.checkout_osnutki
  where id=p_draft_id for update;
  if not found or v_draft.stripe_session_id is distinct from p_session_id then
    raise exception 'Placilna seja ni povezana z osnutkom.';
  end if;
  if v_draft.narocilo_id is not null then
    return jsonb_build_object('ref',v_draft.ref,'order_id',v_draft.narocilo_id);
  end if;
  v_order := v_draft.order_data;
  v_total := round(p_amount_cents::numeric/100,2);
  v_base := round(v_total/1.22,2);
  v_vat := v_total-v_base;
  insert into public.narocila (
    tip,paket,st_boxov,cena_opis,stopnice,krhko,pomoc_polnjenje,
    opis_lokacije,naslov,enota,postna_stevilka,mesto,telefon,
    datum_dostave,cas_dostave,ime,priimek,podjetje,davcna,email,
    stevilka,placano,status,vir
  ) values (
    v_order->>'tip',v_order->>'paket',(v_order->>'st_boxov')::int,
    v_order->>'cena_opis',coalesce((v_order->>'stopnice')::boolean,false),
    coalesce((v_order->>'krhko')::boolean,false),
    coalesce((v_order->>'pomoc_polnjenje')::boolean,false),
    v_order->>'opis_lokacije',v_order->>'naslov',v_order->>'enota',
    v_order->>'postna_stevilka',v_order->>'mesto',v_order->>'telefon',
    (v_order->>'datum_dostave')::date,v_order->>'cas_dostave',
    v_order->>'ime',v_order->>'priimek',v_order->>'podjetje',
    v_order->>'davcna',v_order->>'email',v_draft.ref,true,'nova','splet'
  ) returning * into v_n;
  v_customer := v_n.kupec_id;
  insert into public.racuni (
    narocilo_id,kupec_id,stevilka,osnova,ddv,znesek,valuta,opis,status,
    email,ime,priimek,podjetje,davcna,datum_izdaje,datum_zapadlosti
  ) values (
    v_n.id,v_customer,v_draft.ref,v_base,v_vat,v_total,'EUR',
    coalesce(v_n.paket,'Rabimbox') || ' - prvi mesec','placan',
    v_n.email,v_n.ime,v_n.priimek,v_n.podjetje,v_n.davcna,
    current_date,current_date
  );
  update public.checkout_osnutki set narocilo_id=v_n.id where id=p_draft_id;
  return jsonb_build_object('ref',v_draft.ref,'order_id',v_n.id);
end;
$$;
revoke all on function public.rb_finalize_paid_checkout(uuid,text,integer) from public, anon, authenticated;
grant execute on function public.rb_finalize_paid_checkout(uuid,text,integer) to service_role;

-- Skladiscni seznam prikazuje placana spletna in vsa rocna narocila.
create or replace function public.sklad_zahteve(
  p_offset integer default 0, p_limit integer default 1000
) returns table (
  id bigint, vir text, stevilka text, vrsta text, status text, placano boolean,
  kupec_id bigint, kupec text, stevilka_stranke text, kupec_email text,
  telefon text, st_boxov integer, naslov text, postna_stevilka text,
  mesto text, datum_dostave date, cas_dostave text, opomba text,
  stopnice boolean, pomoc_polnjenje boolean, ustvarjeno timestamptz,
  st_boxov_dejansko integer, znesek_vracila numeric
) language sql stable security definer set search_path = public as $$
  with zdruzeno as (
    select n.id, 'narocilo'::text vir, n.stevilka, coalesce(n.paket,n.tip) vrsta,
      n.status,n.placano,n.kupec_id,
      nullif(btrim(coalesce(n.ime,'')||' '||coalesce(n.priimek,'')),'') kupec,
      k.stevilka_stranke,n.email kupec_email,n.telefon,n.st_boxov::int,
      nullif(btrim(coalesce(n.naslov,'')||
        case when coalesce(n.enota,'')<>'' then ', enota '||n.enota else '' end),'') naslov,
      n.postna_stevilka,n.mesto,n.datum_dostave::date,n.cas_dostave::text,
      n.opis_lokacije opomba,n.stopnice,n.pomoc_polnjenje,n.created_at ustvarjeno,
      n.st_boxov_dejansko,n.znesek_vracila
    from public.narocila n left join public.kupci k on k.id=n.kupec_id
    where n.placano=true or n.vir='rocno'
    union all
    select z.id,'zahteva'::text,null::text,
      coalesce(nullif(split_part(z.opomba,' - ',1),''),'Zahteva'),
      z.status,null::boolean,z.kupec_id,
      nullif(btrim(coalesce(k.ime,'')||' '||coalesce(k.priimek,'')),''),
      k.stevilka_stranke,k.email,k.telefon,
      (select count(*)::int from public.zahteve_dostave_skatle zs where zs.zahteva_id=z.id),
      nullif(btrim(coalesce(k.naslov,'')),''),k.postna_stevilka,k.kraj,
      z.datum_dostave::date,null::text,z.opomba,null::boolean,null::boolean,
      z.datum_zahteve,null::int,null::numeric
    from public.zahteve_dostave z left join public.kupci k on k.id=z.kupec_id
  )
  select * from zdruzeno
  where public.is_staff() and datum_dostave is not null
  order by (status in ('zakljuceno','preklicano')),(status<>'nova'),
    datum_dostave,ustvarjeno desc
  offset greatest(coalesce(p_offset,0),0)
  limit least(coalesce(p_limit,1000),5000);
$$;

-- Zaprtega narocila ali zahtevka ni mogoce znova odpreti z naknadnim klikom.
create or replace function public.sklad_update_zahteva(
  p_id bigint,p_vir text,p_status text,
  p_opomba text default null,p_datum_dostave date default null
) returns integer language plpgsql security definer set search_path=public as $$
declare v_box_status text; v_prizadetih int:=0; v_staro text;
begin
  if not public.is_staff() then raise exception 'Nimate dovoljenja.'; end if;
  if p_status is not null and p_status not in
    ('nova','caka_dostavo','pri_stranki','v_skladiscu','zakljuceno','preklicano')
  then raise exception 'Neveljaven status: %',p_status; end if;
  if p_vir='narocilo' then
    select status into v_staro from public.narocila where id=p_id for update;
    if not found then raise exception 'Narocilo ne obstaja.'; end if;
    if v_staro in ('zakljuceno','preklicano') then
      raise exception 'Zakljucenega narocila ni mogoce spreminjati.';
    end if;
    if not exists (select 1 from public.narocila
      where id=p_id and (placano=true or vir='rocno')) then
      raise exception 'Neplacanega narocila ni mogoce obdelati.';
    end if;
    update public.narocila set
      status=coalesce(p_status,status),
      datum_dostave=coalesce(p_datum_dostave,datum_dostave),
      opis_lokacije=coalesce(p_opomba,opis_lokacije)
    where id=p_id;
  elsif p_vir='zahteva' then
    select status into v_staro from public.zahteve_dostave where id=p_id for update;
    if not found then raise exception 'Zahteva ne obstaja.'; end if;
    if v_staro in ('zakljuceno','preklicano') then
      raise exception 'Zakljucene zahteve ni mogoce spreminjati.';
    end if;
    update public.zahteve_dostave set
      status=coalesce(p_status,status),
      datum_dostave=coalesce(p_datum_dostave,datum_dostave),
      opomba=coalesce(p_opomba,opomba)
    where id=p_id;
  else raise exception 'Neznan vir: %',p_vir; end if;
  v_box_status:=case p_status
    when 'caka_dostavo' then 'rezervirana'
    when 'pri_stranki' then 'pri_stranki'
    when 'v_skladiscu' then 'v_skladiscu' else null end;
  if v_box_status is not null then
    if p_vir='zahteva' then
      update public.skatle s set status=v_box_status
      where s.id in (select zs.skatla_id from public.zahteve_dostave_skatle zs
        where zs.zahteva_id=p_id);
    else
      update public.skatle s set status=v_box_status
      where s.narocnina_id in (select n.id from public.narocnine n
        where n.narocilo_id=p_id);
    end if;
    get diagnostics v_prizadetih=row_count;
  end if;
  if p_vir='zahteva' and p_status='v_skladiscu'
     and exists (select 1 from public.zahteve_dostave z
       where z.id=p_id and z.opomba ilike 'Vračilo%') then
    update public.skatle s set status='na_zalogi',kupec_id=null,
      narocnina_id=null,tip_storitve=null,lokacija=null,updated_at=now()
    where s.id in (select zs.skatla_id from public.zahteve_dostave_skatle zs
      where zs.zahteva_id=p_id);
  end if;
  begin
    insert into public.dnevnik_dejanj(dejanje,opomba,uporabnik,cas)
    values('status_'||p_vir,p_vir||' #'||p_id||' -> '||coalesce(p_status,'?')||
      case when v_prizadetih>0 then ' ('||v_prizadetih||' skatel)' else '' end,
      coalesce(auth.jwt()->>'email','sistem'),now());
  exception when others then null; end;
  return v_prizadetih;
end;
$$;

create or replace function public.rb_prevent_reopen_order()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.status in ('zakljuceno','preklicano')
     and new.status is distinct from old.status then
    raise exception 'Zakljucenega narocila ni mogoce ponovno odpreti.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_prevent_reopen_order on public.narocila;
create trigger trg_prevent_reopen_order before update of status on public.narocila
for each row execute function public.rb_prevent_reopen_order();

-- Zacetek obracunskega obdobja ostane enak do naslednje obnove.
alter table public.narocnine add column if not exists naslednje_st_boxov integer;
alter table public.narocnine add column if not exists naslednja_cena numeric;
alter table public.narocnine add column if not exists sprememba_od date;

-- datum_do je prvi dan naslednjega obdobja (npr. 1.10. -> 1.11.).
update public.narocnine n set datum_do=(n.datum_od+interval '1 month')::date
where n.status='aktivna' and n.datum_od is not null
  and n.datum_do is distinct from (n.datum_od+interval '1 month')::date
  and exists (select 1 from public.narocila o where o.id=n.narocilo_id and o.placano=true);
create or replace function public.rb_fix_first_delivery_period()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.st_boxov_dejansko is null and new.st_boxov_dejansko>0 then
    update public.narocnine n
    set datum_do=(n.datum_od+interval '1 month')::date
    where n.narocilo_id=new.id and n.status='aktivna'
      and n.datum_od is not null;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_fix_first_delivery_period on public.narocila;
create trigger trg_fix_first_delivery_period
after update of st_boxov_dejansko on public.narocila
for each row execute function public.rb_fix_first_delivery_period();

create or replace function public.rb_schedule_price_after_return()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sub bigint; v_count int; v_end date; v_tip text;
begin
  for v_sub in
    select distinct o.narocnina_id
    from oldtab o join newtab n on n.id=o.id
    where o.narocnina_id is not null and n.narocnina_id is distinct from o.narocnina_id
      and o.status in ('pri_stranki','v_skladiscu')
  loop
    select n.datum_do,n.tip into v_end,v_tip
    from public.narocnine n where n.id=v_sub and n.status='aktivna';
    if not found then continue; end if;
    select count(*) into v_count from public.skatle where narocnina_id=v_sub;
    update public.narocnine set
      naslednje_st_boxov=v_count,
      naslednja_cena=public.rb_cena(v_tip,v_count),
      sprememba_od=v_end,
      updated_at=now()
    where id=v_sub;
  end loop;
  return null;
end;
$$;
drop trigger if exists trg_schedule_price_after_return on public.skatle;
create trigger trg_schedule_price_after_return
after update on public.skatle
referencing old table as oldtab new table as newtab
for each statement execute function public.rb_schedule_price_after_return();

-- Delno vracilo po prvi dostavi. Pravkar placanega obdobja ne proracunamo nazaj.
create or replace function public.sklad_vrni_boxe(
  p_narocilo_id bigint,p_skatle bigint[]
) returns integer language plpgsql security definer set search_path=public as $$
declare v_order public.narocila%rowtype; v_count int;
begin
  if not public.is_staff() then raise exception 'Nimate dovoljenja.'; end if;
  select * into v_order from public.narocila where id=p_narocilo_id for update;
  if not found or v_order.status in ('zakljuceno','preklicano') then
    raise exception 'Aktivno narocilo ne obstaja.';
  end if;
  if coalesce(array_length(p_skatle,1),0)=0 then
    raise exception 'Izberite vsaj en box.';
  end if;
  if (select count(*) from public.skatle s
      where s.id=any(p_skatle) and s.narocnina_id in (
        select n.id from public.narocnine n where n.narocilo_id=p_narocilo_id)
        and s.status in ('pri_stranki','v_skladiscu'))
     <> (select count(distinct x) from unnest(p_skatle) x) then
    raise exception 'Izbrani boxi ne pripadajo aktivnemu narocilu.';
  end if;
  update public.skatle set status='na_zalogi',kupec_id=null,
    narocnina_id=null,tip_storitve=null,lokacija=null,updated_at=now()
  where id=any(p_skatle);
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;
revoke all on function public.sklad_vrni_boxe(bigint,bigint[]) from public,anon;
grant execute on function public.sklad_vrni_boxe(bigint,bigint[]) to authenticated;

create or replace function public.rb_apply_scheduled_prices()
returns integer language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update public.narocnine n set
    st_boxov=n.naslednje_st_boxov,
    cena_mesecna=n.naslednja_cena,
    datum_od=n.sprememba_od,
    datum_do=(n.sprememba_od+public.rb_trajanje(n.tip))::date,
    naslednje_st_boxov=null,naslednja_cena=null,sprememba_od=null,
    updated_at=now()
  where n.status='aktivna' and n.sprememba_od is not null
    and n.sprememba_od <= (now() at time zone 'Europe/Ljubljana')::date;
  get diagnostics v_n=row_count;
  return v_n;
end;
$$;
revoke all on function public.rb_apply_scheduled_prices() from public, anon, authenticated;
select cron.schedule(
  'rabimbox-obracun-obnova',
  '5 3 * * *',
  'select public.rb_apply_scheduled_prices();'
)
where not exists (
  select 1 from cron.job where jobname='rabimbox-obracun-obnova'
);

-- Pocistimo stare rezervacije iz prejsnje izvedbe; novi checkout ustvari le osnutek.
create or replace function public.rb_cleanup_unpaid_legacy()
returns integer language plpgsql security definer set search_path = public as $$
declare v_ids bigint[]; v_count integer;
begin
  select array_agg(id) into v_ids from public.narocila
  where placano=false and vir='splet' and created_at<now()-interval '24 hours'
    and status='nova';
  if v_ids is null then return 0; end if;
  update public.skatle s set status='na_zalogi',kupec_id=null,narocnina_id=null,
    tip_storitve=null,updated_at=now()
  where s.narocnina_id in (
    select id from public.narocnine where narocilo_id=any(v_ids)
  );
  update public.narocnine set status='preklicana',updated_at=now()
  where narocilo_id=any(v_ids);
  update public.narocila set status='preklicano' where id=any(v_ids);
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;
revoke all on function public.rb_cleanup_unpaid_legacy() from public,anon,authenticated;
select cron.schedule(
  'rabimbox-ciscenje-neplacanih',
  '15 * * * *',
  'select public.rb_cleanup_unpaid_legacy();'
)
where not exists (
  select 1 from cron.job where jobname='rabimbox-ciscenje-neplacanih'
);
select public.rb_cleanup_unpaid_legacy();
commit;
