-- Dodajalna migracija. Obstoječi računi in plačana obdobja se ne prepisujejo.
begin;
alter table public.narocila add column if not exists is_test boolean not null default false;
alter table public.narocila add column if not exists nacin_placila text;
alter table public.narocnine add column if not exists stripe_customer_id text;
alter table public.narocnine add column if not exists stripe_subscription_id text;
alter table public.narocnine add column if not exists stripe_price_id text;
alter table public.narocnine add column if not exists billing_status text not null default 'rocno';
alter table public.narocnine add column if not exists auto_renew boolean not null default false;
alter table public.narocnine add column if not exists consent_at timestamptz;
alter table public.narocnine add column if not exists consent_version text;
alter table public.narocnine add column if not exists cancel_requested_at timestamptz;
alter table public.narocnine add column if not exists stripe_period_end timestamptz;
alter table public.narocnine add column if not exists is_test boolean not null default false;
alter table public.narocnine add column if not exists stripe_test_clock_id text;
alter table public.racuni add column if not exists stripe_invoice_id text;
alter table public.racuni add column if not exists stripe_stevilka text;
alter table public.racuni add column if not exists obdobje_od date;
alter table public.racuni add column if not exists obdobje_do date;
alter table public.racuni add column if not exists placano boolean not null default false;
alter table public.racuni add column if not exists is_test boolean not null default false;
alter table public.kupci add column if not exists marketing_consent boolean not null default false;
alter table public.kupci add column if not exists marketing_consent_at timestamptz;
alter table public.kupci add column if not exists marketing_unsubscribed_at timestamptz;
create unique index if not exists rb_invoice_stripe_unique on public.racuni(stripe_invoice_id) where stripe_invoice_id is not null;
create unique index if not exists rb_subscription_stripe_unique on public.narocnine(stripe_subscription_id) where stripe_subscription_id is not null;
-- Brskalnik finančnih podatkov ne sme spreminjati. Osebje uporablja preverjene RPC.
revoke insert,update,delete on public.narocila,public.narocnine,public.racuni from anon,authenticated;

create table if not exists public.rb_billing_settings(id boolean primary key default true check(id), enabled boolean not null default false, updated_at timestamptz default now());
insert into public.rb_billing_settings(id) values(true) on conflict do nothing;
create table if not exists public.rb_billing_events(id text primary key, type text not null, processed_at timestamptz, error text, created_at timestamptz default now());
create table if not exists public.rb_email_log(
  id bigint generated always as identity primary key, provider_id text, recipient text not null,
  subject text not null, html text, status text not null default 'pripravljeno', error text,
  attachment_name text, narocilo_id bigint references public.narocila(id) on delete set null,
  racun_id bigint references public.racuni(id) on delete set null, dedup_key text unique,
  is_test boolean not null default false, created_at timestamptz not null default now(), sent_at timestamptz
);
create table if not exists public.rb_billing_queue(narocilo_id bigint primary key references public.narocila(id) on delete cascade, updated_at timestamptz default now(), error text);
alter table public.rb_billing_settings enable row level security;
alter table public.rb_billing_events enable row level security;
alter table public.rb_email_log enable row level security;
alter table public.rb_billing_queue enable row level security;
revoke all on public.rb_billing_settings,public.rb_billing_events,public.rb_email_log,public.rb_billing_queue from anon,authenticated;
grant all on public.rb_billing_settings,public.rb_billing_events,public.rb_email_log,public.rb_billing_queue to service_role;
grant usage,select on sequence public.rb_email_log_id_seq to service_role;

create or replace function public.rb_trajanje(p_tip text) returns interval language sql immutable as $$select interval '30 days'$$;
-- Samo novi začetki; že zaračunanega obdobja ne spreminjamo.
create or replace function public.rb_billing_dates() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    new.is_test:=coalesce((select is_test from public.narocila where id=new.narocilo_id),false);
    new.datum_do:=new.datum_od+30;
  end if;
  return new;
end$$;
drop trigger if exists zz_rb_billing_dates on public.narocnine;
create trigger zz_rb_billing_dates before insert on public.narocnine for each row execute function public.rb_billing_dates();


-- Potrditev dejansko dostavljenega števila ne sme obdobja podaljšati na koledarski mesec.
create or replace function public.rb_fix_first_delivery_period() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.st_boxov_dejansko is null and new.st_boxov_dejansko>0 then
    update public.narocnine n set datum_do=n.datum_od+30 where n.narocilo_id=new.id and n.status='aktivna' and n.datum_od=new.datum_dostave;
  end if;
  return new;
end$$;

-- Dodelitev je atomarna tudi pri sočasnih naročilih; test ne zasede fizičnih boxov.
create or replace function public.narocilo_dodeli_skatle() returns trigger language plpgsql security definer set search_path=public as $$
declare v_n int;v_sub bigint;v_taken int;
begin
  if new.placano is distinct from true and new.vir<>'rocno' then return new;end if;
  v_n:=coalesce(new.st_boxov,0);
  if new.kupec_id is null or v_n=0 then return new;end if;
  if v_n<1 or v_n>5000 then raise exception 'Neveljavno število boxov.';end if;
  insert into public.narocnine(kupec_id,narocilo_id,tip,st_boxov,cena_mesecna,datum_od,status,is_test)
    values(new.kupec_id,new.id,new.tip,v_n,public.rb_cena(new.tip,v_n),coalesce(new.datum_dostave,current_date),'aktivna',new.is_test) returning id into v_sub;
  if not new.is_test then
    with pick as(select id from public.skatle where status='na_zalogi' and kupec_id is null order by id limit v_n for update skip locked)
    update public.skatle s set kupec_id=new.kupec_id,narocnina_id=v_sub,status='rezervirana',tip_storitve=new.tip,updated_at=now() from pick where s.id=pick.id;
    get diagnostics v_taken=row_count;
    if v_taken<>v_n then raise exception 'Trenutno ni dovolj prostih boxov. Naročilo ni bilo shranjeno.';end if;
  end if;
  return new;
end$$;

create or replace function public.rb_billing_tick() returns void language plpgsql security definer set search_path=public as $$
declare v_key text;
begin
  if not exists(select 1 from public.rb_billing_settings where id=true and enabled) then return;end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name='rabimbox_service_role' limit 1;
  if v_key is null then raise exception 'Manjka ključ opravila v Vault.';end if;
  perform net.http_post(url:='https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/rb-billing',headers:=jsonb_build_object('Content-Type','application/json','apikey',v_key),body:=jsonb_build_object('action','worker'));
end$$;
revoke all on function public.rb_billing_tick() from public,anon,authenticated;
select cron.schedule('rabimbox-billing-30dni','*/5 * * * *','select public.rb_billing_tick()') where not exists(select 1 from cron.job where jobname='rabimbox-billing-30dni');

create or replace function public.rb_billing_enqueue() returns trigger language plpgsql security definer set search_path=public as $$
declare v_order bigint;
begin
  if tg_table_name='narocila' then v_order:=new.id;else v_order:=new.narocilo_id;end if;
  if v_order is not null then insert into public.rb_billing_queue(narocilo_id) values(v_order) on conflict(narocilo_id) do update set updated_at=now(); end if;
  return new;
end$$;
drop trigger if exists rb_billing_order_queue on public.narocila;
create trigger rb_billing_order_queue after update of status,datum_dostave on public.narocila for each row execute function public.rb_billing_enqueue();
drop trigger if exists rb_billing_price_queue on public.narocnine;
create trigger rb_billing_price_queue after update of naslednje_st_boxov,naslednja_cena on public.narocnine for each row execute function public.rb_billing_enqueue();
drop trigger if exists rb_billing_return_queue on public.zahteve_dostave;
create trigger rb_billing_return_queue after insert or update of status on public.zahteve_dostave for each row execute function public.rb_billing_enqueue();

-- Pravočasna zahteva za vračilo vseh boxov ustavi naslednje podaljšanje.
create or replace function public.rb_return_stops_renewal(p_order bigint) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.narocnine n where n.narocilo_id=p_order and n.datum_do is not null
    and exists(select 1 from public.skatle s where s.narocnina_id=n.id)
    and not exists(select 1 from public.skatle s where s.narocnina_id=n.id and not exists(
      select 1 from public.zahteve_dostave z join public.zahteve_dostave_skatle zs on zs.zahteva_id=z.id
      where zs.skatla_id=s.id and z.narocilo_id=p_order and z.status<>'preklicano'
        and z.opomba like 'Vračilo%' and (z.datum_zahteve at time zone 'Europe/Ljubljana')::date<=n.datum_do-3
        and (z.datum_dostave at time zone 'Europe/Ljubljana')::date<=n.datum_do
    )));
$$;
revoke all on function public.rb_return_stops_renewal(bigint) from public,anon,authenticated;
grant execute on function public.rb_return_stops_renewal(bigint) to service_role;

-- En plačan Stripe račun se zapiše samo enkrat, obdobje ostane na računu.
create or replace function public.rb_record_stripe_invoice(p_data jsonb) returns bigint language plpgsql security definer set search_path=public as $$
declare v_sub public.narocnine%rowtype; v_order public.narocila%rowtype; v_id bigint; v_total numeric; v_start date; v_end date;
begin
  if auth.role()<>'service_role' then raise exception 'Ni dovoljeno.';end if;
  select * into v_sub from public.narocnine where stripe_subscription_id=p_data->>'subscription_id' for update;
  if not found then raise exception 'Naročnina ni povezana.';end if;
  select * into v_order from public.narocila where id=v_sub.narocilo_id;
  select id into v_id from public.racuni where stripe_invoice_id=p_data->>'invoice_id';
  if found then return v_id;end if;
  v_total:=(p_data->>'amount_cents')::numeric/100;v_start:=(p_data->>'period_start')::date;v_end:=(p_data->>'period_end')::date;
  if v_end-v_start<>30 or v_total<0 then raise exception 'Obdobje ali znesek računa ni veljaven.';end if;
  insert into public.racuni(narocilo_id,kupec_id,stevilka,stripe_invoice_id,stripe_stevilka,osnova,ddv,znesek,valuta,opis,status,placano,email,ime,priimek,podjetje,davcna,datum_izdaje,datum_zapadlosti,url_pdf,obdobje_od,obdobje_do,is_test)
  values(v_order.id,v_order.kupec_id,p_data->>'number',p_data->>'invoice_id',p_data->>'number',round(v_total/1.22,2),v_total-round(v_total/1.22,2),v_total,'EUR',p_data->>'description','placan',true,v_order.email,v_order.ime,v_order.priimek,v_order.podjetje,v_order.davcna,coalesce((p_data->>'issued_at')::date,current_date),coalesce((p_data->>'issued_at')::date,current_date),p_data->>'pdf',v_start,v_end,v_sub.is_test) returning id into v_id;
  update public.narocnine set datum_od=v_start,datum_do=v_end,stripe_period_end=(p_data->>'period_end_ts')::timestamptz,billing_status='active',
    st_boxov=coalesce((p_data->>'box_count')::int,st_boxov),cena_mesecna=v_total,
    naslednje_st_boxov=case when sprememba_od<=v_start then null else naslednje_st_boxov end,
    naslednja_cena=case when sprememba_od<=v_start then null else naslednja_cena end,
    sprememba_od=case when sprememba_od<=v_start then null else sprememba_od end
    where id=v_sub.id and datum_od<=v_start;
  return v_id;
end$$;
revoke all on function public.rb_record_stripe_invoice(jsonb) from public,anon,authenticated;
grant execute on function public.rb_record_stripe_invoice(jsonb) to service_role;

create or replace function public.rb_billing_order_details(p_id bigint) returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('vir',o.vir,'nacin_placila',o.nacin_placila,'cena',coalesce(n.cena_mesecna,public.rb_cena(o.tip,o.st_boxov)),
    'datum_od',n.datum_od,'datum_do',n.datum_do,'datum_narocila',o.created_at,'auto_renew',coalesce(n.auto_renew,false),'billing_status',n.billing_status,'is_test',o.is_test,
    'placano',o.placano,'cancel_requested_at',n.cancel_requested_at)
  from public.narocila o left join lateral(select * from public.narocnine where narocilo_id=o.id order by id desc limit 1)n on true
  where o.id=p_id and (public.is_staff() or o.kupec_id=public.my_kupec_id());
$$;
revoke all on function public.rb_billing_order_details(bigint) from public,anon;
grant execute on function public.rb_billing_order_details(bigint) to authenticated;

-- Volba marketingu se vede ločeno od soglasja k naročilu.
create or replace function public.rb_marketing_preference(p_consent boolean) returns void language plpgsql security definer set search_path=public as $$
begin
  if public.my_kupec_id() is null or p_consent is null then raise exception 'Prijava je potrebna.';end if;
  update public.kupci set marketing_consent=p_consent,marketing_consent_at=case when p_consent then now() else marketing_consent_at end,marketing_unsubscribed_at=case when p_consent then null else now() end where id=public.my_kupec_id();
end$$;
revoke all on function public.rb_marketing_preference(boolean) from public,anon;
grant execute on function public.rb_marketing_preference(boolean) to authenticated;
create or replace function public.rb_invoice_snapshot() returns trigger language plpgsql security definer set search_path=public as $$
declare n public.narocnine%rowtype;o public.narocila%rowtype;
begin
  if tg_op='UPDATE' and old.obdobje_od is not null then
    new.obdobje_od:=old.obdobje_od;new.obdobje_do:=old.obdobje_do;new.opis:=old.opis;
  elsif new.narocilo_id is not null then
    select * into o from public.narocila where id=new.narocilo_id;
    select * into n from public.narocnine where narocilo_id=o.id order by id desc limit 1;
    new.obdobje_od:=coalesce(new.obdobje_od,n.datum_od,o.datum_dostave);
    new.obdobje_do:=coalesce(new.obdobje_do,new.obdobje_od+30);
    if new.opis is null or new.opis like '%prvi mesec%' then
      new.opis:=(case when o.tip='izposoja' then 'Izposoja' else 'Skladiščenje' end)||' '||o.st_boxov||' boxov - obdobje od '||to_char(new.obdobje_od,'DD.MM.YYYY')||' do '||to_char(new.obdobje_do-1,'DD.MM.YYYY');
    end if;
    new.is_test:=o.is_test;
  end if;
  if new.status in ('placan','poslan','posiljanje') then new.placano:=true;end if;
  return new;
end$$;
drop trigger if exists rb_invoice_snapshot on public.racuni;
create trigger rb_invoice_snapshot before insert or update on public.racuni for each row execute function public.rb_invoice_snapshot();

create or replace function public.rb_validate_customer() returns trigger language plpgsql set search_path=public as $$
begin
  if new.email is null or new.email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(new.email)>254 then raise exception 'E-naslov ni veljaven.';end if;
  if length(coalesce(new.ime,''))>100 or length(coalesce(new.priimek,''))>100 or length(coalesce(new.telefon,''))>100 or length(coalesce(new.naslov,''))>300 or length(coalesce(new.kraj,''))>100 then raise exception 'Kontaktni podatki so predolgi.';end if;
  return new;
end$$;
drop trigger if exists rb_validate_customer on public.kupci;
create trigger rb_validate_customer before insert or update of ime,priimek,email,telefon,naslov,kraj on public.kupci for each row execute function public.rb_validate_customer();

create or replace function public.rb_claim_email(p_key text,p_recipient text,p_subject text,p_html text,p_order bigint,p_invoice bigint,p_test boolean,p_attachment text) returns bigint language plpgsql security definer set search_path=public as $$
declare v_id bigint;
begin
  if auth.role()<>'service_role' then raise exception 'Ni dovoljeno.';end if;
  insert into public.rb_email_log(dedup_key,recipient,subject,html,narocilo_id,racun_id,is_test,attachment_name,status)
    values(p_key,p_recipient,p_subject,p_html,p_order,p_invoice,p_test,p_attachment,'posiljanje')
    on conflict(dedup_key) do update set status='posiljanje',error=null,created_at=now()
    where rb_email_log.status='napaka' or (rb_email_log.status='posiljanje' and rb_email_log.created_at<now()-interval '10 minutes')
    returning id into v_id;
  return v_id;
end$$;
revoke all on function public.rb_claim_email(text,text,text,text,bigint,bigint,boolean,text) from public,anon,authenticated;
grant execute on function public.rb_claim_email(text,text,text,text,bigint,bigint,boolean,text) to service_role;
commit;
