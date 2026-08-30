-- ============================================================
-- Rabimbox – VARNOSTNO ZAKLEPANJE (RLS) za narocila, racuni, narocnine
-- Poženi v Supabase → SQL Editor.
--
-- Zakaj: anon (javni) ključ je v brskalniku in je varen SAMO, če RLS
-- omejuje dostop. Brez RLS bi lahko kdorkoli prebral VSA naročila
-- (imena, naslovi, e-pošte, telefoni) in račune. Ta skripta to zaklene.
--
-- "Svoje" = kupec, ki je prijavljen z istim e-naslovom (Supabase Auth).
-- Posodobitve/plačila dela strežnik (Edge funkcije) prek service_role,
-- ki obide RLS – zato iz brskalnika UPDATE/DELETE ni potreben in ni dovoljen.
-- ============================================================

-- Pomožna funkcija (če še ne obstaja): id trenutnega kupca iz Auth
create or replace function public.my_kupec_id()
returns bigint language sql stable security definer set search_path = public as $$
  select id from public.kupci where lower(email) = lower(auth.jwt() ->> 'email') limit 1;
$$;
grant execute on function public.my_kupec_id() to authenticated;

-- ---------------- NAROCILA ----------------
alter table public.narocila enable row level security;

drop policy if exists narocila_insert on public.narocila;
create policy narocila_insert on public.narocila
  for insert to anon, authenticated with check (true);          -- oddaja naročila

drop policy if exists narocila_select_own on public.narocila;
create policy narocila_select_own on public.narocila
  for select to authenticated
  using ( lower(coalesce(email,'')) = lower(auth.jwt() ->> 'email') );  -- vidi samo svoja
-- (brez UPDATE/DELETE policy -> iz brskalnika ni mogoče spreminjati)

-- ---------------- RACUNI ----------------
alter table public.racuni enable row level security;

drop policy if exists racuni_select_own on public.racuni;
create policy racuni_select_own on public.racuni
  for select to authenticated
  using ( lower(coalesce(email,'')) = lower(auth.jwt() ->> 'email')
          or kupec_id = public.my_kupec_id() );
-- (INSERT/UPDATE samo prek service_role – brez policy za brskalnik)

-- ---------------- NAROCNINE ----------------
alter table public.narocnine enable row level security;

drop policy if exists narocnine_select_own on public.narocnine;
create policy narocnine_select_own on public.narocnine
  for select to authenticated
  using ( kupec_id = public.my_kupec_id() );

-- ---------------- POVPRASEVANJA (za vsak slučaj) ----------------
alter table public.povprasevanja enable row level security;
drop policy if exists povp_insert_anon on public.povprasevanja;
create policy povp_insert_anon on public.povprasevanja
  for insert to anon, authenticated with check (true);
-- (brez SELECT policy -> bere samo dashboard/service_role)

-- ---------------- PREVERBA ----------------
-- Po zagonu preveri, da imajo vse RLS vklopljen:
--   select relname, relrowsecurity from pg_class
--   where relname in ('narocila','racuni','narocnine','kupci','skatle','povprasevanja');
--   (relrowsecurity mora biti true povsod)
