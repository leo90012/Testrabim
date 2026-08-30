-- ============================================================
-- Rabimbox – popravki: uskladi plačila + obdobje naročnine 1 mesec
-- Poženi v Supabase → SQL Editor.
-- ============================================================

-- 1) Naročila s plačanim računom označi kot plačana (odpravi neskladje)
update public.narocila n
set placano = true
where placano is not true
  and exists (
    select 1 from public.racuni r
    where r.stevilka = n.stevilka
      and lower(coalesce(r.status, '')) like 'plac%'
  );

-- 2) Obdobje naročnine = 1 mesec (prej 3 za skladiščenje)
create or replace function public.rb_trajanje(p_tip text)
returns interval language sql immutable as $$
  select interval '1 month';
$$;

-- 3) Preračunaj datum poteka obstoječih naročnin na datum_od + 1 mesec
update public.narocnine
set datum_do = (datum_od + interval '1 month' - interval '1 day')::date
where datum_od is not null;

-- Preveri:
--   select stevilka, placano from public.narocila order by id desc;
--   select id, tip, datum_od, datum_do, status from public.narocnine order by id desc;
