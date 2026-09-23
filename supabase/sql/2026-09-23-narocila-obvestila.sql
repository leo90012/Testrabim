-- Rabimbox: placani racuni, datumi dostave in e-postna obvestila.
-- SQL je idempotenten. Skrivnost se prenese iz starega sprozilca v Vault
-- znotraj baze; njena vrednost se nikoli ne izpise ali shrani v repozitorij.

create extension if not exists pg_net;
create extension if not exists pg_cron;

do $migration$
declare
  v_key text;
begin
  if not exists (select 1 from vault.secrets where name = 'rabimbox_service_role') then
    select substring(prosrc from 'Bearer[[:space:]]+([A-Za-z0-9._-]+)')
      into v_key
    from pg_proc
    where proname = 'rb_notify_box_status' and pronamespace = 'public'::regnamespace;
    if v_key is null or length(v_key) < 20 then
      raise exception 'Starega service_role kljuca v sprozilcu ni mogoce najti.';
    end if;
    perform vault.create_secret(v_key, 'rabimbox_service_role', 'Klici Rabimbox Edge funkcij iz baze');
  end if;
end
$migration$;

create table if not exists public.email_obvestila (
  tip text not null,
  vir text not null,
  vir_id bigint not null,
  datum date not null,
  poslano_at timestamptz not null default now(),
  primary key (tip, vir, vir_id, datum)
);
alter table public.email_obvestila enable row level security;
revoke all on public.email_obvestila from anon, authenticated;

-- Racun nastane sele po potrjenem Stripe placilu v strezniski funkciji.
drop policy if exists racuni_insert on public.racuni;
revoke insert on public.racuni from anon, authenticated;
create unique index if not exists racuni_stevilka_unique
  on public.racuni(stevilka) where stevilka is not null;

-- Ob prvi vzpostavitvi narocnine ima termin dostave prednost pred datumom,
-- ki ga je morda vpisal drug sprozilec. Obdobje se premakne za isti zamik.
create or replace function public.rb_narocnina_datumi()
returns trigger language plpgsql set search_path = public as $$
declare v_dostava date; v_prejsnji_zacetek date;
begin
  if tg_op = 'INSERT' and new.narocilo_id is not null then
    select datum_dostave into v_dostava from public.narocila where id = new.narocilo_id;
    if v_dostava is not null then
      v_prejsnji_zacetek := new.datum_od;
      new.datum_od := v_dostava;
      if new.datum_do is not null and v_prejsnji_zacetek is not null then
        new.datum_do := new.datum_do + (v_dostava - v_prejsnji_zacetek);
      else
        new.datum_do := (v_dostava + public.rb_trajanje(new.tip))::date;
      end if;
    end if;
  end if;
  if new.datum_od is null then
    new.datum_od := coalesce((select datum_dostave from public.narocila where id = new.narocilo_id), current_date);
  end if;
  if new.datum_do is null then
    new.datum_do := (new.datum_od + public.rb_trajanje(new.tip))::date;
  end if;
  new.updated_at := now();
  return new;
end; $$;

-- Uskladi ze obstojeca obdobja brez izgube njihovega trajanja.
update public.narocnine n
set datum_do = case when n.datum_do is not null and n.datum_od is not null
                    then n.datum_do + (o.datum_dostave - n.datum_od)
                    else (o.datum_dostave + public.rb_trajanje(n.tip))::date end,
    datum_od = o.datum_dostave
from public.narocila o
where o.id = n.narocilo_id and o.datum_dostave is not null
  and n.datum_od is distinct from o.datum_dostave;

-- Ob spremembi dogovorjenega termina ostane zacetek narocnine usklajen.
create or replace function public.rb_sync_datum_po_spremembi_dostave()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.datum_dostave is not null and new.datum_dostave is distinct from old.datum_dostave then
    update public.narocnine n
    set datum_do = case when n.datum_do is not null and n.datum_od is not null
                        then n.datum_do + (new.datum_dostave - n.datum_od)
                        else (new.datum_dostave + public.rb_trajanje(n.tip))::date end,
        datum_od = new.datum_dostave
    where n.narocilo_id = new.id and n.datum_od is distinct from new.datum_dostave;
  end if;
  return new;
end; $$;
drop trigger if exists trg_sync_datum_dostave on public.narocila;
create trigger trg_sync_datum_dostave
  after update of datum_dostave on public.narocila
  for each row execute function public.rb_sync_datum_po_spremembi_dostave();

-- Ena e-posta na stranko in spremembo statusa. Iz prejsnjega statusa
-- razlocimo prvo dostavo od vrnitve boksov iz skladisca.
create or replace function public.rb_notify_box_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets
    where name = 'rabimbox_service_role' limit 1;
  if v_key is null then raise warning 'Rabimbox: manjka skrivnost za obvestila'; return null; end if;
  for r in
    select k.email, k.ime,
           case when n.status = 'pri_stranki' then 'dostava' else 'prevzem' end as tip,
           case when n.status = 'pri_stranki' and o.status = 'v_skladiscu'
                then 'vrnitev' else 'prva_dostava' end as faza,
           count(*)::int as st_boksov
    from newtab n
    join oldtab o on o.id = n.id
    join public.kupci k on k.id = n.kupec_id
    where (n.status = 'pri_stranki' and o.status is distinct from 'pri_stranki')
       or (n.status = 'v_skladiscu' and o.status = 'pri_stranki')
    group by k.email, k.ime,
             case when n.status = 'pri_stranki' then 'dostava' else 'prevzem' end,
             case when n.status = 'pri_stranki' and o.status = 'v_skladiscu'
                  then 'vrnitev' else 'prva_dostava' end
  loop
    perform net.http_post(
      url := 'https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/poslji-obvestilo',
      headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || v_key,'apikey',v_key),
      body := jsonb_build_object('tip',r.tip,'faza',r.faza,'email',r.email,'ime',r.ime,'st_boksov',r.st_boksov)
    );
  end loop;
  return null;
end; $$;

-- Vsako jutro preveri dostave naslednjega dne. Funkcija sama vodi
-- evidenco, zato ponovno izvajanje ne poslje podvojenih opomnikov.
create or replace function public.rb_send_delivery_reminders()
returns void language plpgsql security definer set search_path = public as $$
declare v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets
    where name = 'rabimbox_service_role' limit 1;
  if v_key is null then raise exception 'Manjka rabimbox_service_role v Vault.'; end if;
  perform net.http_post(
    url := 'https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/poslji-obvestilo',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || v_key,'apikey',v_key),
    body := jsonb_build_object('tip','dostava_opomnik_batch')
  );
end; $$;
revoke all on function public.rb_send_delivery_reminders() from public, anon, authenticated;
select cron.schedule('rabimbox-dostava-opomnik', '0 7 * * *', 'select public.rb_send_delivery_reminders()');
