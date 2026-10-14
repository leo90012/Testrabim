-- Podatki za samodejno izpolnjeno pogodbo v skladiščni aplikaciji.
-- Samo branje; vrne podatke enega naročila in samo prijavljenemu osebju (is_staff).
-- Zaženi v Supabase -> SQL Editor -> Run.
create or replace function public.sklad_pogodba(p_id bigint)
returns table (
  stevilka text, stevilka_stranke text, tip text, st_boxov integer, cena_opis text,
  datum_dostave date, ime text, priimek text, podjetje text, davcna text,
  naslov text, postna_stevilka text, mesto text, telefon text, email text
) language sql stable security definer set search_path = public as $$
  select n.stevilka, k.stevilka_stranke, n.tip, n.st_boxov::int, n.cena_opis,
         n.datum_dostave::date, n.ime, n.priimek, n.podjetje, n.davcna,
         n.naslov, n.postna_stevilka, n.mesto, n.telefon, n.email
  from public.narocila n
  left join public.kupci k on k.id = n.kupec_id
  where n.id = p_id and public.is_staff();
$$;

revoke all on function public.sklad_pogodba(bigint) from public, anon;
grant execute on function public.sklad_pogodba(bigint) to authenticated;
