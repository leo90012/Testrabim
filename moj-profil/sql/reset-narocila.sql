-- ============================================================
-- Rabimbox – RESET: izbriši vsa trenutna naročila + vse boxe na 'na_zalogi'
-- Poženi v Supabase → SQL Editor.
-- POZOR: nepovratno izbriše VSA naročila (tabela narocila).
-- ============================================================

begin;

-- 1) Odveži naročnine od naročil, da brisanje naročil ne spodleti zaradi povezav
update public.narocnine set narocilo_id = null where narocilo_id is not null;

-- 2) Izbriši vsa naročila
delete from public.narocila;

-- 3) Vse boxe postavi na 'na_zalogi' (Pripravljeno za dostavo) in jih sprosti
update public.skatle set status = 'na_zalogi';
update public.skatle set narocnina_id = null where narocnina_id is not null;

commit;

-- ------------------------------------------------------------
-- NEOBVEZNO (če želiš popoln reset – odkomentiraj in poženi posebej):
--   delete from public.narocnine;   -- izbriši vse naročnine
--   delete from public.racuni;      -- izbriši vse račune/predračune
-- ------------------------------------------------------------

-- Preveri rezultat:
--   select count(*) from public.narocila;                       -- pričakovano 0
--   select status, count(*) from public.skatle group by 1;      -- vse na 'na_zalogi'
