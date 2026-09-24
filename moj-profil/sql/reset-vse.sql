-- =====================================================================
--  Rabimbox – POPOLN RESET + 360 boxov v skladišču
--  Izbriše VSE stranke, prijavne račune, naročila, račune, naročnine,
--  povpraševanja in zahteve; nato ustvari točno 360 prostih boxov.
--  Zaženi v Supabase -> SQL Editor -> Run.
--  POZOR: nepovratno! Po želji prej naredi backup (Database -> Backups).
-- =====================================================================

-- 1) Pobriši vezne / odvisne zapise, ki kažejo na boxe
delete from public.zahteve_dostave_skatle;
delete from public.skladisce_dogodki;      -- zgodovina skladišča (če je NE želiš brisati, izbriši to vrstico)

-- 2) Pobriši vse boxe (sprosti tabelo pred vstavljanjem novih)
delete from public.skatle;

-- 3) Pobriši ostale odvisne zapise
delete from public.zahteve_dostave;
delete from public.racuni;
delete from public.narocnine;
delete from public.narocila;
delete from public.povprasevanja;

-- 4) Pobriši stranke in prijavne račune
delete from public.kupci;
delete from auth.users;

-- 5) Ustvari točno 360 prostih boxov v skladišču
--    (barkoda se dodeli samodejno prek triggerja set_barkoda -> RB0001, ...)
--    Če želiš, da barkode začnejo znova pri RB0001, odkomentiraj naslednjo vrstico:
-- alter sequence public.skatle_barkoda_seq restart with 1;

insert into public.skatle (status)
select 'na_zalogi'
from generate_series(1, 360);

-- Preveri rezultat:
-- select count(*) as boxov, status from public.skatle group by status;   -- pričakovano: 360 | na_zalogi
