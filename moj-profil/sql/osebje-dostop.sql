-- ============================================================
--  RABIMBOX – Zaprt dostop do skladiščne aplikacije
--
--  PROBLEM, KI GA REŠUJE:
--  is_staff() in is_admin() sta doslej presojala po e-poštni domeni
--  (@rabimbox.si). Ker so v Supabase registracije odprte in potrjevanje
--  e-pošte izklopljeno, bi se lahko kdorkoli registriral kot
--  karkoli@rabimbox.si in takoj dobil pravice skladiščnika.
--
--  REŠITEV: dostop ima samo tisti, ki je izrecno vpisan v tabelo "osebje".
--  Registracija strank na spletni strani ostane nedotaknjena.
--
--  Zaženi v Supabase: SQL Editor -> prilepi -> Run.  Varno za večkraten zagon.
-- ============================================================


-- ------------------------------------------------------------
-- 1) Tabela osebja
-- ------------------------------------------------------------
create table if not exists public.osebje (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  vloga      text not null check (vloga in ('skladiscnik','admin')),
  opomba     text,
  created_at timestamptz default now()
);

alter table public.osebje enable row level security;

-- Osebje lahko vidi samo svoj zapis; dodaja/briše se izključno tu v SQL
-- urejevalniku (service_role), ne iz brskalnika.
drop policy if exists osebje_select_self on public.osebje;
create policy osebje_select_self on public.osebje
  for select to authenticated
  using ( user_id = auth.uid() );


-- ------------------------------------------------------------
-- 2) Vpiši obstoječa računa
--    admin@rabimbox.si       -> admin
--    skladiscnik@rabimbox.si -> skladiscnik
--
--    info@rabimbox.si NI dodan: ta naslov je tudi med strankami,
--    zato mu namenoma ne dajemo dostopa do skladišča.
-- ------------------------------------------------------------
insert into public.osebje (user_id, vloga, opomba)
select u.id, 'admin', 'glavni administrator'
from auth.users u
where lower(u.email) = 'admin@rabimbox.si'
on conflict (user_id) do update set vloga = excluded.vloga;

insert into public.osebje (user_id, vloga, opomba)
select u.id, 'skladiscnik', 'skladiščnik'
from auth.users u
where lower(u.email) = 'skladiscnik@rabimbox.si'
on conflict (user_id) do update set vloga = excluded.vloga;


-- ------------------------------------------------------------
-- 3) VAROVALO: ne zamenjaj funkcij, če osebje ni vpisano
--    (drugače bi si zaprli dostop do lastne aplikacije)
-- ------------------------------------------------------------
do $$
declare v_st int;
begin
  select count(*) into v_st from public.osebje;
  if v_st < 1 then
    raise exception 'V tabeli osebje ni nobenega zapisa – ustavljam, da ne zapremo dostopa. Preveri, ali računa admin@rabimbox.si in skladiscnik@rabimbox.si obstajata v Authentication -> Users.';
  end if;
  raise notice 'V tabeli osebje je % zapisov – nadaljujem.', v_st;
end
$$;


-- ------------------------------------------------------------
-- 4) Nova is_staff() / is_admin() – po tabeli, ne po e-pošti
-- ------------------------------------------------------------
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.osebje o where o.user_id = auth.uid());
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.osebje o where o.user_id = auth.uid() and o.vloga = 'admin');
$$;

grant execute on function public.is_staff() to authenticated, anon;
grant execute on function public.is_admin() to authenticated, anon;


-- ------------------------------------------------------------
-- 5) Pomožna funkcija za aplikacijo: kdo sem?
--    Aplikacija po prijavi preveri vlogo in neosebje takoj odjavi.
-- ------------------------------------------------------------
create or replace function public.moja_vloga()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select o.vloga from public.osebje o where o.user_id = auth.uid();
$$;

grant execute on function public.moja_vloga() to authenticated;


-- ============================================================
--  KONTROLA – poženi po zagonu
-- ============================================================
-- select o.vloga, u.email from public.osebje o join auth.users u on u.id = o.user_id;
--
--  DODAJANJE NOVEGA DELAVCA (dvostopenjsko):
--   1. Authentication -> Users -> Add user (e-pošta + geslo)
--   2. tukaj:
--      insert into public.osebje (user_id, vloga)
--      select id, 'skladiscnik' from auth.users where lower(email) = 'novi@rabimbox.si'
--      on conflict (user_id) do update set vloga = excluded.vloga;
--
--  ODVZEM DOSTOPA:
--      delete from public.osebje
--      where user_id = (select id from auth.users where lower(email) = 'nekdo@rabimbox.si');
