-- ============================================================
--  RABIMBOX – Prevzem: delavec izbere KONKRETNE škatle
--
--  Nadgradnja prevzem-vracilo.sql: namesto števila boxov delavec
--  odkljuka, katere škatle je stranka res vzela. Tako v vsakem
--  trenutku vemo, kateri box je pri kateri stranki in kateri je
--  nazaj v skladišču.
--
--  Zaženi v Supabase: SQL Editor -> prilepi -> Run.
--  Varno za večkraten zagon.
-- ============================================================


-- ------------------------------------------------------------
-- 1) Škatle naročila s podatkom, ali je škatla ŠE vezana nanj
--    (uporablja se za seznam s kljukicami v aplikaciji)
-- ------------------------------------------------------------
drop function if exists public.sklad_skatle_narocila(bigint);

create or replace function public.sklad_skatle_narocila(p_narocilo_id bigint)
returns table (
  id bigint,
  barkoda text,
  status text,
  lokacija text,
  velikost text,
  pri_stranki boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.barkoda, s.status, s.lokacija, s.velikost,
         (s.status = 'pri_stranki') as pri_stranki
  from public.skatle s
  where public.is_staff()
    and s.narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_narocilo_id)
  order by s.barkoda nulls last, s.id;
$$;

revoke all on function public.sklad_skatle_narocila(bigint) from public, anon;
grant execute on function public.sklad_skatle_narocila(bigint) to authenticated;


-- ------------------------------------------------------------
-- 2) Potrditev prevzema z izbranimi škatlami
--
--    p_skatle = seznam ID-jev škatel, ki jih je stranka VZELA.
--    Vse ostale škatle tega naročila se sprostijo nazaj v zalogo.
-- ------------------------------------------------------------
create or replace function public.sklad_potrdi_prevzem_izbrane(
  p_narocilo_id bigint,
  p_skatle bigint[],
  p_opomba text default null
)
returns table (
  naroceno int,
  vzeto int,
  vrnjeno_v_zalogo int,
  cena_prvotna numeric,
  cena_koncna numeric,
  vracilo numeric,
  barkode_vzete text,
  barkode_vrnjene text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nar        public.narocila%rowtype;
  v_naroceno   int;
  v_vzeto      int;
  v_sprosceno  int := 0;
  v_cena_prej  numeric;
  v_cena_potem numeric;
  v_vracilo    numeric;
  v_vzete_txt  text;
  v_vrnj_txt   text;
  v_izbrane    bigint[];
begin
  if not public.is_staff() then
    raise exception 'Nimate dovoljenja.';
  end if;

  select * into v_nar from public.narocila where id = p_narocilo_id;
  if not found then
    raise exception 'Naročilo % ne obstaja.', p_narocilo_id;
  end if;

  v_izbrane := coalesce(p_skatle, array[]::bigint[]);

  -- vse škatle tega naročila
  create temp table if not exists _skatle_narocila (id bigint) on commit drop;
  delete from _skatle_narocila;
  insert into _skatle_narocila (id)
  select s.id from public.skatle s
  where s.narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_narocilo_id);

  select count(*) into v_naroceno from _skatle_narocila;
  if v_naroceno = 0 then
    raise exception 'Temu naročilu ni dodeljena nobena škatla, zato prevzema ni mogoče potrditi.';
  end if;

  -- izbrane morajo pripadati temu naročilu
  if exists (select 1 from unnest(v_izbrane) x(id)
             where x.id not in (select id from _skatle_narocila)) then
    raise exception 'Med izbranimi je škatla, ki ne pripada temu naročilu.';
  end if;

  v_vzeto := array_length(v_izbrane, 1);
  if v_vzeto is null then v_vzeto := 0; end if;

  -- barkode za dnevnik in povratno informacijo
  select string_agg(coalesce(s.barkoda,'#'||s.id), ', ' order by s.barkoda)
    into v_vzete_txt
  from public.skatle s where s.id = any(v_izbrane);

  select string_agg(coalesce(s.barkoda,'#'||s.id), ', ' order by s.barkoda)
    into v_vrnj_txt
  from public.skatle s
  where s.id in (select id from _skatle_narocila) and not (s.id = any(v_izbrane));

  -- ------------------------------------------------------
  -- izbrane -> pri stranki
  -- ------------------------------------------------------
  update public.skatle
  set status = 'pri_stranki'
  where id = any(v_izbrane);

  -- ------------------------------------------------------
  -- neizbrane -> nazaj v zalogo (odvežemo od stranke in naročnine)
  -- ------------------------------------------------------
  update public.skatle
  set status       = 'na_zalogi',
      kupec_id     = null,
      narocnina_id = null,
      lokacija     = null
  where id in (select id from _skatle_narocila)
    and not (id = any(v_izbrane));
  get diagnostics v_sprosceno = row_count;

  -- ------------------------------------------------------
  -- cena po ceniku za dejansko količino
  -- ------------------------------------------------------
  v_cena_prej  := public.rb_cena(v_nar.tip, coalesce(v_nar.st_boxov, v_naroceno));
  v_cena_potem := public.rb_cena(v_nar.tip, v_vzeto);
  v_vracilo    := greatest(v_cena_prej - v_cena_potem, 0);

  update public.narocnine
  set st_boxov     = v_vzeto,
      cena_mesecna = v_cena_potem,
      status       = case when v_vzeto = 0 then 'preklicana' else status end
  where narocilo_id = p_narocilo_id;

  update public.narocila
  set st_boxov_dejansko = v_vzeto,
      cena_prvotna      = v_cena_prej,
      cena_koncna       = v_cena_potem,
      znesek_vracila    = v_vracilo,
      prevzem_cas       = now(),
      prevzem_uporabnik = coalesce(auth.jwt() ->> 'email', 'sistem'),
      opis_lokacije     = coalesce(p_opomba, opis_lokacije),
      status            = case when v_vzeto = 0 then 'preklicano' else 'pri_stranki' end
  where id = p_narocilo_id;

  -- dnevnik
  begin
    insert into public.dnevnik_dejanj (dejanje, opomba, uporabnik, cas)
    values ('prevzem',
            'narocilo #' || p_narocilo_id || ': vzeto ' || v_vzeto || ' od ' || v_naroceno ||
            case when v_vzete_txt is not null then ' [' || v_vzete_txt || ']' else '' end ||
            case when v_sprosceno > 0 then ' | v zalogo ' || v_sprosceno ||
                      coalesce(' [' || v_vrnj_txt || ']','') else '' end ||
            case when v_vracilo > 0 then ' | vracilo ' || v_vracilo || ' EUR' else '' end,
            coalesce(auth.jwt() ->> 'email','sistem'), now());
  exception when others then null;
  end;

  return query select v_naroceno, v_vzeto, v_sprosceno,
                      v_cena_prej, v_cena_potem, v_vracilo,
                      coalesce(v_vzete_txt,''), coalesce(v_vrnj_txt,'');
end;
$$;

revoke all on function public.sklad_potrdi_prevzem_izbrane(bigint,bigint[],text) from public, anon;
grant execute on function public.sklad_potrdi_prevzem_izbrane(bigint,bigint[],text) to authenticated;


-- ------------------------------------------------------------
-- 3) Predogled: koliko bi bilo vračilo za izbrano število škatel
--    (že obstaja kot sklad_predogled_vracila – tu samo potrdimo,
--     da je na voljo tudi po tej nadgradnji)
-- ------------------------------------------------------------
-- select * from public.sklad_predogled_vracila(1, 20);


-- ============================================================
--  KONTROLA
-- ============================================================
-- select * from public.sklad_skatle_narocila(1);
-- select * from public.sklad_potrdi_prevzem_izbrane(1, array[1,2,3]::bigint[], 'Stranka vzela 3 boxe');
