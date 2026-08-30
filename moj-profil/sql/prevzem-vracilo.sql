-- ============================================================
--  RABIMBOX – Prevzem: dejansko število boxov + delno vračilo
--
--  Zaženi v Supabase: SQL Editor -> prilepi -> Run
--  Varno za večkraten zagon (idempotentno).
--
--  Kaj naredi:
--   1) Cenik v bazi (rb_cena) – ista logika kot na spletni strani
--   2) Nova polja na naročilu: dejansko št. boxov, znesek vračila
--   3) sklad_potrdi_prevzem(): delavec vpiše, koliko boxov je stranka
--      res vzela; odvečni boxi gredo samodejno nazaj v zalogo,
--      cena se prevrednoti po ceniku, razlika se zabeleži kot vračilo
-- ============================================================


-- ------------------------------------------------------------
-- 1) CENIK (isti kot v checkoutu)
--    izposoja:     20 -> 49, 40 -> 89, 60 -> 119, 80 -> 149
--                  (uporabi se najmanjši paket, ki zadošča)
--    skladiscenje: do 10 -> 3,90/box, do 25 -> 3,60, do 50 -> 3,30
-- ------------------------------------------------------------
create or replace function public.rb_cena(p_tip text, p_boxov int)
returns numeric
language sql
immutable
as $$
  select case
    when coalesce(p_boxov,0) <= 0 then 0::numeric
    when lower(coalesce(p_tip,'')) like 'sklad%' then
      round(p_boxov * case
        when p_boxov <= 10 then 3.90
        when p_boxov <= 25 then 3.60
        when p_boxov <= 50 then 3.30
        else 3.30 end, 2)
    else
      case
        when p_boxov <= 20 then 49.00
        when p_boxov <= 40 then 89.00
        when p_boxov <= 60 then 119.00
        when p_boxov <= 80 then 149.00
        else round(149.00 * ceil(p_boxov::numeric / 80), 2)
      end
  end;
$$;

comment on function public.rb_cena(text,int) is
  'Mesecna cena po ceniku Rabimbox za dano vrsto storitve in stevilo boxov.';


-- ------------------------------------------------------------
-- 2) Nova polja na naročilu
-- ------------------------------------------------------------
alter table public.narocila add column if not exists st_boxov_dejansko int;
alter table public.narocila add column if not exists znesek_vracila   numeric(10,2);
alter table public.narocila add column if not exists cena_prvotna     numeric(10,2);
alter table public.narocila add column if not exists cena_koncna      numeric(10,2);
alter table public.narocila add column if not exists prevzem_cas      timestamptz;
alter table public.narocila add column if not exists prevzem_uporabnik text;


-- ------------------------------------------------------------
-- 3) Delavec potrdi prevzem: koliko boxov je stranka res vzela
--
--    - odvečne škatle se sprostijo nazaj v zalogo
--      (status 'na_zalogi', brez kupca in brez naročnine)
--    - naročnina se popravi na dejansko količino in ceno
--    - razlika v ceni se zabeleži kot znesek_vracila
--    - naročilo dobi status 'pri_stranki', vzete škatle prav tako
-- ------------------------------------------------------------
create or replace function public.sklad_potrdi_prevzem(
  p_narocilo_id bigint,
  p_st_boxov_dejansko int,
  p_opomba text default null
)
returns table (
  naroceno int,
  vzeto int,
  vrnjeno_v_zalogo int,
  cena_prvotna numeric,
  cena_koncna numeric,
  vracilo numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nar        public.narocila%rowtype;
  v_naroceno   int;
  v_cena_prej  numeric;
  v_cena_potem numeric;
  v_vracilo    numeric;
  v_sprosceno  int := 0;
  v_id         bigint;
begin
  if not public.is_staff() then
    raise exception 'Nimate dovoljenja.';
  end if;

  select * into v_nar from public.narocila where id = p_narocilo_id;
  if not found then
    raise exception 'Naročilo % ne obstaja.', p_narocilo_id;
  end if;

  v_naroceno := coalesce(v_nar.st_boxov, 0);

  if p_st_boxov_dejansko is null or p_st_boxov_dejansko < 0 then
    raise exception 'Število prevzetih boxov ni veljavno.';
  end if;
  if p_st_boxov_dejansko > v_naroceno then
    raise exception 'Stranka ne more vzeti več boxov (%), kot jih je naročila (%).',
      p_st_boxov_dejansko, v_naroceno;
  end if;

  -- cena prej in potem (po ceniku)
  v_cena_prej  := public.rb_cena(v_nar.tip, v_naroceno);
  v_cena_potem := public.rb_cena(v_nar.tip, p_st_boxov_dejansko);
  v_vracilo    := greatest(v_cena_prej - v_cena_potem, 0);

  -- ------------------------------------------------------
  -- sprosti odvečne škatle nazaj v zalogo
  -- ------------------------------------------------------
  for v_id in
    select s.id
    from public.skatle s
    where s.narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_narocilo_id)
    order by s.id
    offset p_st_boxov_dejansko          -- prvih N obdrži stranka
  loop
    update public.skatle
    set status       = 'na_zalogi',
        kupec_id     = null,
        narocnina_id = null,
        lokacija     = null
    where id = v_id;
    v_sprosceno := v_sprosceno + 1;
  end loop;

  -- škatle, ki jih je stranka vzela, gredo "pri_stranki"
  update public.skatle
  set status = 'pri_stranki'
  where narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_narocilo_id);

  -- ------------------------------------------------------
  -- popravi naročnino na dejansko količino in ceno
  -- ------------------------------------------------------
  update public.narocnine
  set st_boxov     = p_st_boxov_dejansko,
      cena_mesecna = v_cena_potem,
      status       = case when p_st_boxov_dejansko = 0 then 'preklicana' else status end
  where narocilo_id = p_narocilo_id;

  -- ------------------------------------------------------
  -- zabeleži na naročilu
  -- ------------------------------------------------------
  update public.narocila
  set st_boxov_dejansko = p_st_boxov_dejansko,
      cena_prvotna      = v_cena_prej,
      cena_koncna       = v_cena_potem,
      znesek_vracila    = v_vracilo,
      prevzem_cas       = now(),
      prevzem_uporabnik = coalesce(auth.jwt() ->> 'email', 'sistem'),
      opis_lokacije     = coalesce(p_opomba, opis_lokacije),
      status            = case when p_st_boxov_dejansko = 0 then 'preklicano' else 'pri_stranki' end
  where id = p_narocilo_id;

  -- dnevnik
  begin
    insert into public.dnevnik_dejanj (dejanje, opomba, uporabnik, cas)
    values ('prevzem',
            'narocilo #' || p_narocilo_id || ': vzeto ' || p_st_boxov_dejansko || ' od ' || v_naroceno ||
            ', v zalogo ' || v_sprosceno ||
            case when v_vracilo > 0 then ', vracilo ' || v_vracilo || ' EUR' else '' end,
            coalesce(auth.jwt() ->> 'email','sistem'), now());
  exception when others then null;
  end;

  return query select v_naroceno, p_st_boxov_dejansko, v_sprosceno,
                      v_cena_prej, v_cena_potem, v_vracilo;
end;
$$;

revoke all on function public.sklad_potrdi_prevzem(bigint,int,text) from public, anon;
grant execute on function public.sklad_potrdi_prevzem(bigint,int,text) to authenticated;


-- ------------------------------------------------------------
-- 4) Predogled izračuna (brez sprememb) – za prikaz v aplikaciji
-- ------------------------------------------------------------
create or replace function public.sklad_predogled_vracila(
  p_narocilo_id bigint,
  p_st_boxov_dejansko int
)
returns table (naroceno int, cena_prvotna numeric, cena_koncna numeric, vracilo numeric)
language sql
stable
security definer
set search_path = public
as $$
  select n.st_boxov::int,
         public.rb_cena(n.tip, n.st_boxov::int),
         public.rb_cena(n.tip, p_st_boxov_dejansko),
         greatest(public.rb_cena(n.tip, n.st_boxov::int)
                - public.rb_cena(n.tip, p_st_boxov_dejansko), 0)
  from public.narocila n
  where n.id = p_narocilo_id and public.is_staff();
$$;

revoke all on function public.sklad_predogled_vracila(bigint,int) from public, anon;
grant execute on function public.sklad_predogled_vracila(bigint,int) to authenticated;


-- ------------------------------------------------------------
-- 5) Dopolni delovni seznam z novimi polji
--    (funkcija dobi dva nova stolpca, zato jo je treba najprej odstraniti)
-- ------------------------------------------------------------
drop function if exists public.sklad_zahteve(int,int);

create or replace function public.sklad_zahteve(p_offset int default 0, p_limit int default 1000)
returns table (
  id bigint, vir text, stevilka text, vrsta text, status text, placano boolean,
  kupec_id bigint, kupec text, stevilka_stranke text, kupec_email text, telefon text,
  st_boxov int, naslov text, postna_stevilka text, mesto text,
  datum_dostave date, cas_dostave text, opomba text,
  stopnice boolean, pomoc_polnjenje boolean, ustvarjeno timestamptz,
  st_boxov_dejansko int, znesek_vracila numeric
)
language sql stable security definer set search_path = public as $$
  with zdruzeno (id, vir, stevilka, vrsta, status, placano, kupec_id, kupec,
                 stevilka_stranke, kupec_email, telefon, st_boxov, naslov,
                 postna_stevilka, mesto, datum_dostave, cas_dostave, opomba,
                 stopnice, pomoc_polnjenje, ustvarjeno,
                 st_boxov_dejansko, znesek_vracila) as (
    select n.id, 'narocilo'::text, n.stevilka,
           coalesce(n.paket, n.tip), n.status, n.placano, n.kupec_id,
           nullif(btrim(coalesce(n.ime,'') || ' ' || coalesce(n.priimek,'')),''),
           k.stevilka_stranke, n.email, n.telefon, n.st_boxov::int,
           nullif(btrim(coalesce(n.naslov,'') ||
             case when coalesce(n.enota,'')<>'' then ', enota ' || n.enota else '' end),''),
           n.postna_stevilka, n.mesto, n.datum_dostave::date, n.cas_dostave::text,
           n.opis_lokacije, n.stopnice, n.pomoc_polnjenje, n.created_at,
           n.st_boxov_dejansko, n.znesek_vracila
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
           z.opomba, null::boolean, null::boolean, z.datum_zahteve,
           null::int, null::numeric
    from public.zahteve_dostave z
    left join public.kupci k on k.id = z.kupec_id
  )
  select * from zdruzeno
  where public.is_staff()
    and datum_dostave is not null
  order by (status in ('zakljuceno','preklicano')),
           (status <> 'nova'),
           datum_dostave, ustvarjeno desc
  offset p_offset limit p_limit;
$$;

revoke all on function public.sklad_zahteve(int,int) from public, anon;
grant execute on function public.sklad_zahteve(int,int) to authenticated;


-- ============================================================
--  KONTROLA
-- ============================================================
-- select public.rb_cena('izposoja',20), public.rb_cena('izposoja',40),
--        public.rb_cena('skladiscenje',20), public.rb_cena('skladiscenje',30);
-- select * from public.sklad_predogled_vracila(1, 20);
-- select * from public.sklad_potrdi_prevzem(1, 20, 'Stranka vzela manj');
