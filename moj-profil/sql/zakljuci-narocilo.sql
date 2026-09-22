-- ============================================================
--  RABIMBOX – Zaključek naročila z vrnitvijo boksov v zalogo
--
--  Ko stranka vrne bokse, skladiščnik naročilo zaključi:
--    - vsi boksi tega naročila gredo nazaj v zalogo
--      (status 'na_zalogi', brez stranke, brez naročnine, brez lokacije)
--    - naročnina se zaključi (datum_do = danes, status 'zakljucena')
--    - naročilo dobi status 'zakljuceno' in izgine iz odprtih
--
--  Zaženi v Supabase: SQL Editor -> prilepi -> Run.
--  Varno za večkraten zagon.
-- ============================================================


-- ------------------------------------------------------------
-- 1) Predogled: koliko boksov bo šlo nazaj v zalogo
--    (aplikacija to pokaže v potrditvenem vprašanju)
-- ------------------------------------------------------------
create or replace function public.sklad_predogled_zakljucka(p_narocilo_id bigint)
returns table (boksov int, barkode text)
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int,
         coalesce(string_agg(coalesce(s.barkoda, '#' || s.id), ', ' order by s.barkoda), '')
  from public.skatle s
  where public.is_staff()
    and s.narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_narocilo_id);
$$;

revoke all on function public.sklad_predogled_zakljucka(bigint) from public, anon;
grant execute on function public.sklad_predogled_zakljucka(bigint) to authenticated;


-- ------------------------------------------------------------
-- 2) Zaključek naročila
-- ------------------------------------------------------------
create or replace function public.sklad_zakljuci_narocilo(
  p_narocilo_id bigint,
  p_opomba text default null
)
returns table (
  vrnjenih_boksov int,
  barkode_vrnjene text,
  narocnina_zakljucena boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nar      public.narocila%rowtype;
  v_vrnjenih int := 0;
  v_txt      text;
  v_nar_ok   boolean := false;
begin
  if not public.is_staff() then
    raise exception 'Nimate dovoljenja.';
  end if;

  select * into v_nar from public.narocila where id = p_narocilo_id;
  if not found then
    raise exception 'Naročilo % ne obstaja.', p_narocilo_id;
  end if;

  if v_nar.status = 'zakljuceno' then
    raise exception 'Naročilo je že zaključeno.';
  end if;

  -- barkode boksov, ki jih vračamo (za dnevnik in povratno informacijo)
  select string_agg(coalesce(s.barkoda, '#' || s.id), ', ' order by s.barkoda)
    into v_txt
  from public.skatle s
  where s.narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_narocilo_id);

  -- vsi boksi naročila nazaj v zalogo
  update public.skatle
  set status       = 'na_zalogi',
      kupec_id     = null,
      narocnina_id = null,
      lokacija     = null,
      updated_at   = now()
  where narocnina_id in (select n.id from public.narocnine n where n.narocilo_id = p_narocilo_id);
  get diagnostics v_vrnjenih = row_count;

  -- zaključi naročnino
  update public.narocnine
  set status     = 'zakljucena',
      datum_do   = least(coalesce(datum_do, current_date), current_date),
      updated_at = now()
  where narocilo_id = p_narocilo_id;
  v_nar_ok := found;

  -- zaključi naročilo
  update public.narocila
  set status        = 'zakljuceno',
      opis_lokacije = coalesce(p_opomba, opis_lokacije)
  where id = p_narocilo_id;

  -- dnevnik
  begin
    insert into public.dnevnik_dejanj (dejanje, opomba, uporabnik, cas)
    values ('zakljucek',
            'narocilo #' || p_narocilo_id || ': zakljuceno, v zalogo ' || v_vrnjenih || ' boksov' ||
            coalesce(' [' || v_txt || ']', ''),
            coalesce(auth.jwt() ->> 'email', 'sistem'), now());
  exception when others then null;
  end;

  return query select v_vrnjenih, coalesce(v_txt, ''), v_nar_ok;
end;
$$;

revoke all on function public.sklad_zakljuci_narocilo(bigint,text) from public, anon;
grant execute on function public.sklad_zakljuci_narocilo(bigint,text) to authenticated;


-- ============================================================
--  KONTROLA
-- ============================================================
-- select * from public.sklad_predogled_zakljucka(1);
-- select * from public.sklad_zakljuci_narocilo(1, 'Stranka vrnila vse bokse');
