-- =====================================================================
--  Rabimbox – pobriši vse boxe in ustvari točno 360 čistih (na_zalogi)
--  Brez test škatel: vse obstoječe pobriše, barkode začnejo pri RB000001.
--  Zaženi v Supabase -> SQL Editor -> Run.
-- =====================================================================

-- 1) Pobriši vezne zapise na boxe (sicer tuji ključi ne pustijo brisanja)
delete from public.zahteve_dostave_skatle;
delete from public.skladisce_dogodki;      -- zgodovina skladišča (če je NE želiš brisati, izbriši to vrstico)

-- 2) Pobriši vse boxe
delete from public.skatle;

-- 3) Resetiraj številčenje barkod, da začnejo pri RB000001 (brez test ostankov)
alter sequence public.skatle_barkoda_seq restart with 1;

-- 4) Ustvari točno 360 prostih boxov v skladišču
insert into public.skatle (status)
select 'na_zalogi'
from generate_series(1, 360);

-- Preveri:
-- select count(*) as boxov, status from public.skatle group by status;   -- pričakovano: 360 | na_zalogi
