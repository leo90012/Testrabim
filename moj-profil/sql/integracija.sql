-- ============================================================
--  RABIMBOX – Integracija spletne strani in skladiščne aplikacije
--
--  Zaženi v Supabase: Dashboard -> SQL Editor -> prilepi vse -> Run
--  Skripta je varna za večkraten zagon (idempotentna).
--
--  Kaj naredi:
--   1) Poenoti statuse (škatle, naročila, zahteve, naročnine)
--   2) Samodejno izračuna datume naročnin
--   3) Doda funkcije, da skladiščnik vidi in obdeluje naročila strank
-- ============================================================


-- ============================================================
--  DEL 1) POENOTENJE STATUSOV
-- ============================================================

-- ------------------------------------------------------------
-- 1a) Statusi ŠKATEL – kje je škatla fizično
--     na_zalogi | rezervirana | v_transportu | pri_stranki
--     v_skladiscu | poskodovana | umaknjena
-- ------------------------------------------------------------
update public.skatle set status = 'pri_stranki'  where lower(status) in ('zasedena','zaseden','zasedeno','izposojena','pri kupcu');
update public.skatle set status = 'na_zalogi'    where lower(status) in ('prost','prosta','prosto','free');
update public.skatle set status = 'v_skladiscu'  where lower(status) in ('skladisce','skladišče','v skladiscu','v skladišču');
update public.skatle set status = 'v_transportu' where lower(status) in ('dostava','v dostavi','transport');
update public.skatle set status = 'na_zalogi'    where status is null or btrim(status) = '';

alter table public.skatle drop constraint if exists skatle_status_chk;
alter table public.skatle add constraint skatle_status_chk
  check (status in ('na_zalogi','rezervirana','v_transportu','pri_stranki','v_skladiscu','poskodovana','umaknjena'));

-- ------------------------------------------------------------
-- 1b) Statusi NAROČIL in ZAHTEV – enake vrednosti v obeh tabelah
--     nova         = novo, še neobdelano  (delavec ga mora prevzeti)
--     caka_dostavo = potrjeno, čaka na dostavo
--     pri_stranki  = boxi so pri stranki
--     v_skladiscu  = boxi so v skladišču
--     zakljuceno   = opravljeno
--     preklicano   = preklicano
-- ------------------------------------------------------------
do $mig$
declare t text;
begin
  foreach t in array array['narocila','zahteve_dostave'] loop
    execute format($f$
      update public.%I set status = 'caka_dostavo' where lower(status) like 'caka%%' or lower(status) like 'čaka%%' or lower(status) like 'potrj%%';
      update public.%I set status = 'pri_stranki'  where lower(status) like 'pri stranki%%' or lower(status) like 'dostavlj%%';
      update public.%I set status = 'v_skladiscu'  where lower(status) like 'v skladis%%' or lower(status) like 'v skladiš%%' or lower(status) like 'prevzet%%';
      update public.%I set status = 'zakljuceno'   where lower(status) like 'zaklju%%' or lower(status) like 'opravlj%%';
      update public.%I set status = 'preklicano'   where lower(status) like 'preklic%%' or lower(status) like 'zavrn%%';
      update public.%I set status = 'nova'         where status is null
             or status not in ('nova','caka_dostavo','pri_stranki','v_skladiscu','zakljuceno','preklicano');
    $f$, t,t,t,t,t,t);
  end loop;
end
$mig$;

alter table public.narocila drop constraint if exists narocila_status_chk;
alter table public.narocila add constraint narocila_status_chk
  check (status in ('nova','caka_dostavo','pri_stranki','v_skladiscu','zakljuceno','preklicano'));

alter table public.zahteve_dostave drop constraint if exists zd_status_chk;
alter table public.zahteve_dostave add constraint zd_status_chk
  check (status in ('nova','caka_dostavo','pri_stranki','v_skladiscu','zakljuceno','preklicano'));

-- ------------------------------------------------------------
-- 1c) Statusi NAROČNIN: aktivna | pavza | zakljucena | preklicana
-- ------------------------------------------------------------
update public.narocnine set status = 'aktivna'    where lower(status) like 'aktiv%';
update public.narocnine set status = 'zakljucena' where lower(status) like 'zaklju%' or lower(status) like 'konc%';
update public.narocnine set status = 'preklicana' where lower(status) like 'preklic%';
update public.narocnine set status = 'pavza'      where lower(status) like 'pavz%' or lower(status) like 'zamrz%';
update public.narocnine set status = 'aktivna'    where status is null;

alter table public.narocnine drop constraint if exists narocnine_status_chk;
alter table public.narocnine add constraint narocnine_status_chk
  check (status in ('aktivna','pavza','zakljucena','preklicana'));

-- ------------------------------------------------------------
-- 1d) status_narocnine pri kupcih (bila mešanica "aktivna"/"Neaktiven")
-- ------------------------------------------------------------
update public.kupci set status_narocnine = 'aktivna'    where lower(status_narocnine) like 'aktiv%';
update public.kupci set status_narocnine = 'neaktivna'  where lower(status_narocnine) like 'neaktiv%';
update public.kupci set status_narocnine = 'preklicana' where lower(status_narocnine) like 'preklic%';


-- ============================================================
--  DEL 2) DATUMI NAROČNINE – EN VIR RESNICE
-- ============================================================

create or replace function public.rb_trajanje(p_tip text)
returns interval language sql immutable as $$
  -- Min. obdobje naročnine je 1 mesec (izposoja in skladiščenje).
  select interval '1 month';
$$;

create or replace function public.rb_narocnina_datumi()
returns trigger language plpgsql as $$
begin
  if new.datum_od is null then
    new.datum_od := coalesce(
      (select n.datum_dostave from public.narocila n where n.id = new.narocilo_id),
      current_date);
  end if;
  if new.datum_do is null then
    new.datum_do := (new.datum_od + public.rb_trajanje(new.tip))::date;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_narocnina_datumi on public.narocnine;
create trigger trg_narocnina_datumi
  before insert or update on public.narocnine
  for each row execute function public.rb_narocnina_datumi();

update public.narocnine
set datum_od = coalesce(datum_od,
      (select n.datum_dostave from public.narocila n where n.id = narocnine.narocilo_id), current_date)
where datum_od is null;

update public.narocnine
set datum_do = (datum_od + public.rb_trajanje(tip))::date
where datum_do is null;

-- kupci.* postane samo odsev tabele narocnine
create or replace function public.rb_sync_kupec_narocnina()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_kupec bigint;
begin
  v_kupec := coalesce(new.kupec_id, old.kupec_id);
  if v_kupec is null then return coalesce(new, old); end if;
  update public.kupci k
  set datum_zacetka_narocnine = s.od,
      datum_konca_narocnine   = s.do_,
      status_narocnine        = case when s.aktivnih > 0 then 'aktivna' else 'neaktivna' end
  from (
    select min(datum_od) filter (where status='aktivna') as od,
           max(datum_do) filter (where status='aktivna') as do_,
           count(*)      filter (where status='aktivna') as aktivnih
    from public.narocnine where kupec_id = v_kupec
  ) s
  where k.id = v_kupec;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_kupec_narocnina on public.narocnine;
create trigger trg_sync_kupec_narocnina
  after insert or update or delete on public.narocnine
  for each row execute function public.rb_sync_kupec_narocnina();

update public.kupci k
set datum_zacetka_narocnine = s.od,
    datum_konca_narocnine   = s.do_,
    status_narocnine        = case when s.aktivnih > 0 then 'aktivna' else 'neaktivna' end
from (
  select kupec_id,
         min(datum_od) filter (where status='aktivna') as od,
         max(datum_do) filter (where status='aktivna') as do_,
         count(*)      filter (where status='aktivna') as aktivnih
  from public.narocnine group by kupec_id
) s
where k.id = s.kupec_id;

-- Pogled za stranko: škatla + veljavnost njene naročnine
create or replace view public.moje_skatle as
select s.id, s.kupec_id, s.barkoda, s.velikost, s.status, s.lokacija,
       s.tip_storitve, s.narocnina_id, s.opomba, s.updated_at,
       n.datum_od as narocnina_od, n.datum_do as narocnina_do, n.status as narocnina_status
from public.skatle s
left join public.narocnine n on n.id = s.narocnina_id;

alter view public.moje_skatle set (security_invoker = on);
grant select on public.moje_skatle to authenticated;


-- ============================================================
--  DEL 3) SKLADIŠČNIK VIDI IN OBDELUJE NAROČILA STRANK
-- ============================================================

-- ------------------------------------------------------------
-- 3a) Združen delovni seznam: naročila iz checkouta + zahteve iz panela
--     Vrne VSA naročila (tudi zaključena); filtriranje je v aplikaciji.
-- ------------------------------------------------------------
create or replace function public.sklad_zahteve(p_offset int default 0, p_limit int default 1000)
returns table (
  id bigint, vir text, stevilka text, vrsta text, status text, placano boolean,
  kupec_id bigint, kupec text, stevilka_stranke text, kupec_email text, telefon text,
  st_boxov int, naslov text, postna_stevilka text, mesto text,
  datum_dostave date, cas_dostave text, opomba text,
  stopnice boolean, pomoc_polnjenje boolean, ustvarjeno timestamptz
)
language sql stable security definer set search_path = public as $$
  with zdruzeno (id, vir, stevilka, vrsta, status, placano, kupec_id, kupec,
                 stevilka_stranke, kupec_email, telefon, st_boxov, naslov,
                 postna_stevilka, mesto, datum_dostave, cas_dostave, opomba,
                 stopnice, pomoc_polnjenje, ustvarjeno) as (
    select n.id, 'narocilo'::text, n.stevilka,
           coalesce(n.paket, n.tip), n.status, n.placano, n.kupec_id,
           nullif(btrim(coalesce(n.ime,'') || ' ' || coalesce(n.priimek,'')),''),
           k.stevilka_stranke, n.email, n.telefon, n.st_boxov::int,
           nullif(btrim(coalesce(n.naslov,'') ||
             case when coalesce(n.enota,'')<>'' then ', enota ' || n.enota else '' end),''),
           n.postna_stevilka, n.mesto, n.datum_dostave::date, n.cas_dostave::text,
           n.opis_lokacije, n.stopnice, n.pomoc_polnjenje, n.created_at
    from public.narocila n
    left join public.kupci k on k.id = n.kupec_id
    union all
    select z.id, 'zahteva'::text, null::text,
           coalesce(nullif(split_part(z.opomba,' - ',1),''),'Zahteva'), z.status, null::boolean, z.kupec_id,
           nullif(btrim(coalesce(k.ime,'') || ' ' || coalesce(k.priimek,'')),''),
           k.stevilka_stranke, k.email, k.telefon,
           (select count(*)::int from public.zahteve_dostave_skatle zs where zs.zahteva_id = z.id),
           nullif(btrim(coalesce(k.naslov,'')),''),
           k.postna_stevilka, k.kraj, z.datum_dostave::date, null::text,
           z.opomba, null::boolean, null::boolean, z.datum_zahteve
    from public.zahteve_dostave z
    left join public.kupci k on k.id = z.kupec_id
  )
  select * from zdruzeno
  where public.is_staff()
    and datum_dostave is not null      -- naročila brez termina se ne prikazujejo
  order by (status in ('zakljuceno','preklicano')),   -- odprta najprej
           (status <> 'nova'),                        -- nova čisto na vrh
           datum_dostave, ustvarjeno desc
  offset p_offset limit p_limit;
$$;

revoke all on function public.sklad_zahteve(int,int) from public, anon;
grant execute on function public.sklad_zahteve(int,int) to authenticated;

-- ------------------------------------------------------------
-- 3b) Škatle, vezane na posamezno naročilo/zahtevo
-- ------------------------------------------------------------
create or replace function public.sklad_zahteva_skatle(p_id bigint, p_vir text default 'zahteva')
returns table (id bigint, barkoda text, status text, lokacija text, vezana boolean)
language sql stable security definer set search_path = public as $$
  with kupec as (
    select case when p_vir = 'narocilo'
                then (select n.kupec_id from public.narocila n where n.id = p_id)
                else (select z.kupec_id from public.zahteve_dostave z where z.id = p_id) end as kid
  ),
  vezane as (
    select s.id
    from public.skatle s
    where (p_vir = 'zahteva' and s.id in (
             select zs.skatla_id from public.zahteve_dostave_skatle zs where zs.zahteva_id = p_id))
       or (p_vir = 'narocilo' and s.narocnina_id in (
             select n.id from public.narocnine n where n.narocilo_id = p_id))
  )
  select s.id, s.barkoda, s.status, s.lokacija, (v.id is not null) as vezana
  from public.skatle s
  left join vezane v on v.id = s.id
  where public.is_staff()
    and (
      s.id in (select id from vezane)
      -- ce naročilu ni vezana nobena škatla, pokažemo vse škatle te stranke
      or (not exists (select 1 from vezane) and s.kupec_id = (select kid from kupec))
    )
  order by (v.id is null), s.id;
$$;

drop function if exists public.sklad_zahteva_skatle(bigint);
revoke all on function public.sklad_zahteva_skatle(bigint,text) from public, anon;
grant execute on function public.sklad_zahteva_skatle(bigint,text) to authenticated;

-- ------------------------------------------------------------
-- 3c) Delavec spremeni stanje naročila
--     Statusi, ki premaknejo tudi ŠKATLE:
--       caka_dostavo -> škatle "rezervirana"
--       pri_stranki  -> škatle "pri_stranki"
--       v_skladiscu  -> škatle "v_skladiscu"
-- ------------------------------------------------------------
create or replace function public.sklad_update_zahteva(
  p_id bigint,
  p_vir text,
  p_status text,
  p_opomba text default null,
  p_datum_dostave date default null
)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_box_status text;
  v_prizadetih int := 0;
begin
  if not public.is_staff() then
    raise exception 'Nimate dovoljenja.';
  end if;
  if p_status is not null and p_status not in
     ('nova','caka_dostavo','pri_stranki','v_skladiscu','zakljuceno','preklicano') then
    raise exception 'Neveljaven status: %', p_status;
  end if;

  if p_vir = 'narocilo' then
    update public.narocila
    set status        = coalesce(p_status, status),
        datum_dostave = coalesce(p_datum_dostave, datum_dostave),
        opis_lokacije = coalesce(p_opomba, opis_lokacije)
    where id = p_id;
  elsif p_vir = 'zahteva' then
    update public.zahteve_dostave
    set status        = coalesce(p_status, status),
        datum_dostave = coalesce(p_datum_dostave, datum_dostave),
        opomba        = coalesce(p_opomba, opomba)
    where id = p_id;
  else
    raise exception 'Neznan vir: %', p_vir;
  end if;

  -- premakni še škatle
  v_box_status := case p_status
                    when 'caka_dostavo' then 'rezervirana'
                    when 'pri_stranki'  then 'pri_stranki'
                    when 'v_skladiscu'  then 'v_skladiscu'
                    else null end;

  if v_box_status is not null then
    if p_vir = 'zahteva' then
      update public.skatle s set status = v_box_status
      where s.id in (select zs.skatla_id from public.zahteve_dostave_skatle zs where zs.zahteva_id = p_id);
    else
      update public.skatle s set status = v_box_status
      where s.narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_id);
    end if;
    get diagnostics v_prizadetih = row_count;
  end if;

  begin
    insert into public.dnevnik_dejanj (dejanje, opomba, uporabnik, cas)
    values ('status_' || p_vir,
            p_vir || ' #' || p_id || ' -> ' || coalesce(p_status,'?') ||
            case when v_prizadetih > 0 then ' (' || v_prizadetih || ' skatel)' else '' end,
            coalesce(auth.jwt() ->> 'email','sistem'), now());
  exception when others then null;
  end;

  return v_prizadetih;
end;
$$;

revoke all on function public.sklad_update_zahteva(bigint,text,text,text,date) from public, anon;
grant execute on function public.sklad_update_zahteva(bigint,text,text,text,date) to authenticated;

-- ------------------------------------------------------------
-- 3d) Števci za značke na zavihkih
-- ------------------------------------------------------------
create or replace function public.sklad_stevci()
returns table (nova int, odprta int, danes int)
language sql stable security definer set search_path = public as $$
  with vse as (
    select status, datum_dostave::date d from public.narocila
    union all
    select status, datum_dostave::date from public.zahteve_dostave
  )
  select
    (select count(*)::int from vse where status = 'nova'),
    (select count(*)::int from vse where status not in ('zakljuceno','preklicano')),
    (select count(*)::int from vse where d = current_date and status not in ('zakljuceno','preklicano'))
  where public.is_staff();
$$;

revoke all on function public.sklad_stevci() from public, anon;
grant execute on function public.sklad_stevci() to authenticated;


-- ============================================================
--  KONTROLA – poženi po zagonu in preveri izpise
-- ============================================================
-- select status, count(*) from public.skatle group by 1;
-- select 'narocila' t, status, count(*) from public.narocila group by 1,2
--   union all select 'zahteve', status, count(*) from public.zahteve_dostave group by 1,2;
-- select id, tip, datum_od, datum_do, status from public.narocnine order by id;
-- select * from public.sklad_zahteve(0,50);
-- select * from public.sklad_stevci();


-- ============================================================
--  DEL 4) VAROVALO: samodejni prevod starih vrednosti statusa
--  Poskrbi, da naročilo s spletne strani ne pade, tudi če
--  koda še vpisuje staro vrednost (npr. "novo" namesto "nova").
-- ============================================================
create or replace function public.rb_normaliziraj_status()
returns trigger language plpgsql as $$
begin
  new.status := case
    when new.status is null then 'nova'
    when lower(new.status) like 'nov%' then 'nova'
    when lower(new.status) like 'caka%' or lower(new.status) like 'čaka%' or lower(new.status) like 'potrj%' then 'caka_dostavo'
    when lower(new.status) like 'pri stranki%' or lower(new.status) like 'pri_stranki%' or lower(new.status) like 'dostavlj%' then 'pri_stranki'
    when lower(new.status) like 'v sklad%' or lower(new.status) like 'v_sklad%' or lower(new.status) like 'prevzet%' then 'v_skladiscu'
    when lower(new.status) like 'zaklju%' or lower(new.status) like 'opravlj%' then 'zakljuceno'
    when lower(new.status) like 'preklic%' or lower(new.status) like 'zavrn%' then 'preklicano'
    else new.status end;
  return new;
end;
$$;

drop trigger if exists trg_norm_status_narocila on public.narocila;
create trigger trg_norm_status_narocila
  before insert or update of status on public.narocila
  for each row execute function public.rb_normaliziraj_status();

drop trigger if exists trg_norm_status_zahteve on public.zahteve_dostave;
create trigger trg_norm_status_zahteve
  before insert or update of status on public.zahteve_dostave
  for each row execute function public.rb_normaliziraj_status();
