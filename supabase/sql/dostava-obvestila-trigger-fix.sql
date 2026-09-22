-- ============================================================
--  RABIMBOX – POPRAVEK: ena e-pošta na naročilo, ne na vsak box
--
--  TEŽAVA:
--  Prožilec trg_box_status_notify je bil nastavljen "FOR EACH ROW",
--  zato je ob spremembi statusa poslal en zahtevek za VSAKO škatlo.
--  Stranka z 40 boksi je ob dostavi prejela 40 e-poštnih sporočil.
--  (Potrjeno v net._http_response: 40 zahtevkov v isti minuti.)
--
--  REŠITEV:
--  Prožilec postane "FOR EACH STATEMENT" s prehodnima tabelama.
--  Ne glede na to, koliko boksov se spremeni naenkrat, gre ven
--  ENA e-pošta na stranko, z navedenim številom boksov.
--
--  Service_role ključ se prebere iz obstoječe funkcije, zato ga
--  ni treba nikamor vpisovati.
--
--  Zaženi v Supabase: SQL Editor -> prilepi -> Run.
-- ============================================================

do $mig$
declare
  v_key text;
begin
  -- ključ iz trenutne različice funkcije
  select substring(prosrc from 'Bearer\s+([A-Za-z0-9._\-]+)')
    into v_key
  from pg_proc
  where proname = 'rb_notify_box_status'
    and pronamespace = 'public'::regnamespace;

  if v_key is null or length(v_key) < 20 then
    raise exception 'Iz obstoječe funkcije ni bilo mogoče prebrati service_role ključa. Preveri, ali je dostava-obvestila-trigger.sql sploh bil pognan.';
  end if;

  execute format($f$
    create or replace function public.rb_notify_box_status()
    returns trigger
    language plpgsql
    security definer
    set search_path = public
    as $b$
    declare r record;
    begin
      for r in
        select k.email                                   as email,
               k.ime                                     as ime,
               case when n.status = 'pri_stranki'
                    then 'dostava' else 'prevzem' end    as tip,
               count(*)::int                             as st_boksov
        from newtab n
        join oldtab o on o.id = n.id
        join public.kupci k on k.id = n.kupec_id
        where (n.status = 'pri_stranki' and coalesce(o.status,'') <> 'pri_stranki')
           or (n.status = 'v_skladiscu' and coalesce(o.status,'') = 'pri_stranki')
        group by k.email, k.ime,
                 case when n.status = 'pri_stranki'
                      then 'dostava' else 'prevzem' end
      loop
        if r.email is not null then
          perform net.http_post(
            url     := 'https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/poslji-obvestilo',
            headers := jsonb_build_object(
                         'Content-Type', 'application/json',
                         'Authorization', 'Bearer %s'
                       ),
            body    := jsonb_build_object(
                         'tip', r.tip,
                         'email', r.email,
                         'ime', r.ime,
                         'st_boksov', r.st_boksov
                       )
          );
        end if;
      end loop;
      return null;
    end;
    $b$;
  $f$, v_key);

  raise notice 'Funkcija rb_notify_box_status posodobljena (ena e-posta na operacijo).';
end
$mig$;


-- Prožilec na raven stavka, s prehodnima tabelama
drop trigger if exists trg_box_status_notify on public.skatle;

-- Opomba: "update of status" tu ni dovoljen – PostgreSQL ne dovoli
-- prehodnih tabel skupaj s seznamom stolpcev. Filtriranje po spremembi
-- statusa je zato znotraj funkcije (primerjava oldtab/newtab).
create trigger trg_box_status_notify
  after update on public.skatle
  referencing old table as oldtab new table as newtab
  for each statement
  execute function public.rb_notify_box_status();


-- ============================================================
--  KONTROLA – po zagonu mora pisati FOR EACH STATEMENT
-- ============================================================
-- select t.tgname,
--        case when t.tgtype & 1 = 1 then 'FOR EACH ROW' else 'FOR EACH STATEMENT' end as nacin
-- from pg_trigger t join pg_class c on c.oid = t.tgrelid
-- where c.relname = 'skatle' and not t.tgisinternal;
--
--  Koliko zahtevkov je slo ven v zadnji uri (prej = stevilo boksov, zdaj = 1):
-- select date_trunc('minute', created) as minuta, count(*)
-- from net._http_response where created > now() - interval '1 hour'
-- group by 1 order by 1 desc;
