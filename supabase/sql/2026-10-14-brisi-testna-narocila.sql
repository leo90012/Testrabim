-- =====================================================================
--  Izbris profilov info@rabim-lj.si in sadadasdasdas@gmail.com
--  (prijavni račun, stranka, njuna naročila, računi, naročnine, zahteve)
--  ter naročila RB-2026-E3E10E35-163 (z njegovim računom).
--  Zaženi v Supabase -> SQL Editor. NAJPREJ 1. KORAK (pregled), nato 2. KORAK.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. KORAK – PREGLED (samo branje). Preveri, da je na seznamu res samo to,
--    kar želiš izbrisati.
-- ---------------------------------------------------------------------
with e(email) as (values ('info@rabim-lj.si'), ('sadadasdasdas@gmail.com')),
nar as (
  select id from public.narocila
  where lower(trim(email)) in (select email from e) or stevilka = 'RB-2026-E3E10E35-163'
),
kup as (select id from public.kupci where lower(trim(email)) in (select email from e))
select 'prijavni račun' kaj, u.email ident, u.created_at::text podrobnosti from auth.users u where lower(u.email) in (select email from e)
union all select 'stranka', k.email, coalesce(k.ime,'')||' '||coalesce(k.priimek,'') from public.kupci k where k.id in (select id from kup)
union all select 'naročilo', n.stevilka, n.email||' | '||coalesce(n.status,'')||' | plačano='||coalesce(n.placano::text,'-') from public.narocila n where n.id in (select id from nar)
union all select 'račun', r.stevilka, r.email||' | '||coalesce(r.status,'') from public.racuni r
  where r.narocilo_id in (select id from nar) or r.kupec_id in (select id from kup) or lower(trim(r.email)) in (select email from e)
union all select 'zahteva', z.id::text, z.opomba from public.zahteve_dostave z where z.kupec_id in (select id from kup)
union all select 'box '||s.status, s.barkoda, 'bo vrnjen v zalogo' from public.skatle s
  where s.kupec_id in (select id from kup)
     or s.narocnina_id in (select id from public.narocnine where narocilo_id in (select id from nar) or kupec_id in (select id from kup))
order by 1, 2;


-- ---------------------------------------------------------------------
-- 2. KORAK – BRISANJE (nepovratno). Vse ali nič: ob kateri koli napaki se nič ne izbriše.
-- ---------------------------------------------------------------------
begin;

do $$
declare
  v_emails text[] := array['info@rabim-lj.si','sadadasdasdas@gmail.com'];
  v_nar bigint[]; v_kup bigint[]; v_nn bigint[]; v_zah bigint[]; v_usr uuid[];
  v_n int;
begin
  select coalesce(array_agg(id),'{}') into v_nar from public.narocila
   where lower(trim(email)) = any(v_emails) or stevilka = 'RB-2026-E3E10E35-163';
  select coalesce(array_agg(id),'{}') into v_kup from public.kupci
   where lower(trim(email)) = any(v_emails);
  select coalesce(array_agg(id),'{}') into v_nn from public.narocnine
   where narocilo_id = any(v_nar) or kupec_id = any(v_kup);
  select coalesce(array_agg(id),'{}') into v_zah from public.zahteve_dostave
   where kupec_id = any(v_kup);
  select coalesce(array_agg(id),'{}') into v_usr from auth.users
   where lower(email) = any(v_emails);

  -- Varovalo 1: boxov, ki so pri stranki, na poti ali v skladišču, ne vračamo samodejno.
  select count(*) into v_n from public.skatle
   where (kupec_id = any(v_kup) or narocnina_id = any(v_nn))
     and status in ('pri_stranki','v_transportu','v_skladiscu');
  if v_n > 0 then
    raise exception 'Ustavljeno: % boxov je pri stranki, na poti ali v skladišču. Nič ni izbrisano.', v_n;
  end if;

  -- Varovalo 2: ne brišemo računa zaposlenega.
  select count(*) into v_n from public.osebje where user_id = any(v_usr);
  if v_n > 0 then
    raise exception 'Ustavljeno: eden od naslovov je v tabeli osebje. Nič ni izbrisano.';
  end if;

  -- Rezervirani boxi nazaj v zalogo.
  update public.skatle set status='na_zalogi', kupec_id=null, narocnina_id=null
   where kupec_id = any(v_kup) or narocnina_id = any(v_nn);

  -- Računi.
  delete from public.racuni
   where narocilo_id = any(v_nar) or kupec_id = any(v_kup) or lower(trim(email)) = any(v_emails);

  -- Zahteve iz panela in povezave z naročili.
  delete from public.zahteve_dostave_skatle where zahteva_id = any(v_zah);
  delete from public.zahteve_dostave where id = any(v_zah);
  update public.zahteve_dostave set narocilo_id = null where narocilo_id = any(v_nar);

  -- Osnutki plačil, naročnine, naročila.
  delete from public.checkout_osnutki
   where narocilo_id = any(v_nar) or lower(trim(order_data->>'email')) = any(v_emails);
  delete from public.narocnine where id = any(v_nn);
  delete from public.narocila where id = any(v_nar);

  -- Stranka in prijavni račun.
  delete from public.kupci where id = any(v_kup);
  delete from auth.users where id = any(v_usr);

  raise notice 'Izbrisano – naročil: %, strank: %, prijavnih računov: %',
    coalesce(array_length(v_nar,1),0), coalesce(array_length(v_kup,1),0), coalesce(array_length(v_usr,1),0);
end $$;

commit;

-- Preveri (vse mora vrniti 0):
-- select count(*) from auth.users where lower(email) in ('info@rabim-lj.si','sadadasdasdas@gmail.com');
-- select count(*) from public.kupci where lower(trim(email)) in ('info@rabim-lj.si','sadadasdasdas@gmail.com');
-- select count(*) from public.narocila where stevilka = 'RB-2026-E3E10E35-163'
--    or lower(trim(email)) in ('info@rabim-lj.si','sadadasdasdas@gmail.com');
