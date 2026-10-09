-- =====================================================================
--  Rabimbox – dodaj 1000 novih prostih boxov (na_zalogi)
--  Obstoječih boxov ne spreminja. Oznake (RB0361, RB0362, ...) dodeli
--  sprožilec set_barkoda() iz števca skatle_barkoda_seq.
--  Zaženi v Supabase -> SQL Editor -> Run.
-- =====================================================================
begin;
lock table public.skatle in share row exclusive mode;

do $$
declare
  v_zadnja bigint;
begin
  -- Varovalo: skripta je bila že zagnana (ne dodaj še enkrat 1000 boxov).
  if exists (select 1 from public.skatle where opomba = 'Serija 2026-10-08 (1000 novih)') then
    raise exception 'Serija 2026-10-08 je že dodana. Skripte ne zaganjaj dvakrat.';
  end if;

  -- Varovalo: števec oznak ima mejo 5000 (RB5000).
  select last_value into v_zadnja from public.skatle_barkoda_seq;
  if v_zadnja + 1000 > 5000 then
    raise exception 'Premalo prostih oznak: števec je na %, meja je 5000.', v_zadnja;
  end if;
end $$;

insert into public.skatle (status, opomba)
select 'na_zalogi', 'Serija 2026-10-08 (1000 novih)'
from generate_series(1, 1000);

do $$
begin
  if (select count(*) from public.skatle
      where opomba = 'Serija 2026-10-08 (1000 novih)'
        and status = 'na_zalogi' and kupec_id is null
        and barkoda ~ '^RB[0-9]{4}$') <> 1000 then
    raise exception 'Preverjanje ni uspelo – nič ni bilo dodano.';
  end if;
end $$;
commit;

-- Preveri:
-- select status, count(*) from public.skatle group by status order by status;
-- select min(barkoda), max(barkoda) from public.skatle where opomba = 'Serija 2026-10-08 (1000 novih)';
