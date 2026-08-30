-- ============================================================
--  Rabimbox – varnostne nastavitve (Auth + RLS)
--  Zaženi v Supabase: Dashboard -> SQL Editor -> prilepi -> Run
-- ------------------------------------------------------------
--  Kaj naredi:
--   1) Pomožno funkcijo, ki iz prijavljenega uporabnika (Auth)
--      poišče njegovo vrstico v tabeli "kupci" (po e-naslovu).
--   2) Vklopi Row Level Security (RLS) in doda pravila, da vsak
--      kupec vidi/uredi SAMO svoje podatke.
--   3) Neobvezno: ustvari tabelo "racuni" za posamezne račune.
--
--  Predpogoj: e-naslov v tabeli "kupci" se mora ujemati z
--  e-naslovom, s katerim se stranka prijavi (Supabase Auth).
-- ============================================================

-- ------------------------------------------------------------
-- 1) Pomožna funkcija: id trenutnega kupca
-- ------------------------------------------------------------
create or replace function public.my_kupec_id()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select id
  from public.kupci
  where lower(email) = lower(auth.jwt() ->> 'email')
  limit 1;
$$;

grant execute on function public.my_kupec_id() to authenticated;

-- ------------------------------------------------------------
-- 1b) Polja za naslov stranke (za zavihek Profil)
--     (že dodano; varno je zagnati znova)
-- ------------------------------------------------------------
alter table public.kupci add column if not exists naslov text;
alter table public.kupci add column if not exists postna_stevilka text;
alter table public.kupci add column if not exists kraj text;

-- ------------------------------------------------------------
-- 2) Vklop RLS
-- ------------------------------------------------------------
alter table public.kupci                  enable row level security;
alter table public.skatle                 enable row level security;
alter table public.zahteve_dostave        enable row level security;
alter table public.zahteve_dostave_skatle enable row level security;
alter table public.dnevnik_dejanj         enable row level security;

-- ------------------------------------------------------------
-- 3) Pravila: KUPCI (vidi in ureja samo svojo vrstico)
-- ------------------------------------------------------------
drop policy if exists kupci_select_own on public.kupci;
create policy kupci_select_own on public.kupci
  for select to authenticated
  using ( lower(email) = lower(auth.jwt() ->> 'email') );

drop policy if exists kupci_update_own on public.kupci;
create policy kupci_update_own on public.kupci
  for update to authenticated
  using ( lower(email) = lower(auth.jwt() ->> 'email') )
  with check ( lower(email) = lower(auth.jwt() ->> 'email') );

-- ------------------------------------------------------------
-- 4) Pravila: SKATLE (samo svoje boxe – samo branje)
-- ------------------------------------------------------------
drop policy if exists skatle_select_own on public.skatle;
create policy skatle_select_own on public.skatle
  for select to authenticated
  using ( kupec_id = public.my_kupec_id() );

-- ------------------------------------------------------------
-- 5) Pravila: ZAHTEVE_DOSTAVE (svoje zahteve – branje + oddaja)
-- ------------------------------------------------------------
drop policy if exists zd_select_own on public.zahteve_dostave;
create policy zd_select_own on public.zahteve_dostave
  for select to authenticated
  using ( kupec_id = public.my_kupec_id() );

drop policy if exists zd_insert_own on public.zahteve_dostave;
create policy zd_insert_own on public.zahteve_dostave
  for insert to authenticated
  with check ( kupec_id = public.my_kupec_id() );

drop policy if exists zd_update_own on public.zahteve_dostave;
create policy zd_update_own on public.zahteve_dostave
  for update to authenticated
  using ( kupec_id = public.my_kupec_id() )
  with check ( kupec_id = public.my_kupec_id() );

-- ------------------------------------------------------------
-- 6) Pravila: ZAHTEVE_DOSTAVE_SKATLE (vezni zapisi)
-- ------------------------------------------------------------
drop policy if exists zds_select_own on public.zahteve_dostave_skatle;
create policy zds_select_own on public.zahteve_dostave_skatle
  for select to authenticated
  using ( zahteva_id in (select id from public.zahteve_dostave where kupec_id = public.my_kupec_id()) );

drop policy if exists zds_insert_own on public.zahteve_dostave_skatle;
create policy zds_insert_own on public.zahteve_dostave_skatle
  for insert to authenticated
  with check ( zahteva_id in (select id from public.zahteve_dostave where kupec_id = public.my_kupec_id()) );

-- ------------------------------------------------------------
-- 7) Pravila: DNEVNIK_DEJANJ (samo branje dogodkov svojih boxov)
-- ------------------------------------------------------------
drop policy if exists dd_select_own on public.dnevnik_dejanj;
create policy dd_select_own on public.dnevnik_dejanj
  for select to authenticated
  using ( skatla_id in (select id from public.skatle where kupec_id = public.my_kupec_id()) );

-- ============================================================
-- 8) NEOBVEZNO: tabela za posamezne račune
--    Odkomentiraj (odstrani /* in */) in zaženi, če želiš
--    prikaz računov v zavihku "Računi".
-- ============================================================
/*
create table if not exists public.racuni (
  id               bigint generated by default as identity primary key,
  kupec_id         bigint references public.kupci(id) on delete cascade,
  stevilka         text,
  znesek           numeric(10,2),
  valuta           text default 'EUR',
  status           text default 'odprt',      -- odprt | placan | zapadlo
  datum_izdaje     date default current_date,
  datum_zapadlosti date,
  url_pdf          text,
  created_at       timestamptz default now()
);

alter table public.racuni enable row level security;

drop policy if exists racuni_select_own on public.racuni;
create policy racuni_select_own on public.racuni
  for select to authenticated
  using ( kupec_id = public.my_kupec_id() );
*/

-- ============================================================
-- 9) Checkout: dodatna polja naročila + tabela povpraševanj
-- ============================================================
alter table public.narocila add column if not exists postna_stevilka text;
alter table public.narocila add column if not exists mesto text;
-- status plačila (obkljukaš v Table Editorju = plačano)
alter table public.narocila add column if not exists placano boolean default false;

create table if not exists public.povprasevanja (
  id         bigint generated by default as identity primary key,
  ime        text,
  priimek    text,
  email      text,
  telefon    text,
  vprasanje  text not null,
  paket      text,
  tip        text,
  created_at timestamptz default now()
);
alter table public.povprasevanja enable row level security;
drop policy if exists povp_insert_anon on public.povprasevanja;
create policy povp_insert_anon on public.povprasevanja
  for insert to anon, authenticated with check (true);
-- (branje samo prek service_role / dashboarda)
