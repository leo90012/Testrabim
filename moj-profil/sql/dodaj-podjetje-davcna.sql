-- =====================================================================
--  Rabimbox – dodaj podjetje in davčno številko na naročila in račune
--  (za račune na podjetje). Neobvezna podatka; če sta izpolnjena,
--  se izpišeta na PDF računu/predračunu. Zaženi v Supabase SQL Editor.
-- =====================================================================
alter table public.narocila add column if not exists podjetje text;
alter table public.narocila add column if not exists davcna  text;
alter table public.racuni   add column if not exists podjetje text;
alter table public.racuni   add column if not exists davcna  text;
