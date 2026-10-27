-- Interna potrditev, preprečevanje dvojnih prevozov in ročna prva dostava.
begin;

-- Box je zaklenjen samo za nov zahtevek, njegov fizični status ostane enak.
create or replace function public.rb_pending_transport_boxes()
returns table(skatla_id bigint,zahteva_id bigint)
language sql stable security definer set search_path=public as $$
  select zs.skatla_id,z.id
  from public.zahteve_dostave z
  join public.zahteve_dostave_skatle zs on zs.zahteva_id=z.id
  where z.kupec_id=public.my_kupec_id()
    and coalesce(z.status,'nova') not in
      ('pri_stranki','v_skladiscu','dostavljeno','prevzeto','opravljeno',
       'zakljuceno','zakljucena','preklicano','preklicana','zavrnjeno','zavrnjena');
$$;
revoke all on function public.rb_pending_transport_boxes() from public,anon,authenticated;
grant execute on function public.rb_pending_transport_boxes() to authenticated;
create index if not exists zahteve_dostave_skatle_box_idx
  on public.zahteve_dostave_skatle(skatla_id,zahteva_id);

CREATE OR REPLACE FUNCTION public.sklad_update_zahteva(p_id bigint, p_vir text, p_status text, p_opomba text DEFAULT NULL::text, p_datum_dostave date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_box_status text; v_prizadetih int:=0; v_staro text;
begin
  if not public.is_staff() then raise exception 'Nimate dovoljenja.'; end if;
  if p_status is not null and p_status not in
    ('nova','caka_dostavo','pri_stranki','v_skladiscu','zakljuceno','preklicano')
  then raise exception 'Neveljaven status: %',p_status; end if;
  if p_vir='narocilo' then
    select status into v_staro from public.narocila where id=p_id for update;
    if not found then raise exception 'Narocilo ne obstaja.'; end if;
    if v_staro in ('zakljuceno','preklicano') then
      raise exception 'Zakljucenega narocila ni mogoce spreminjati.';
    end if;
    if not exists (select 1 from public.narocila
      where id=p_id and (placano=true or vir='rocno')) then
      raise exception 'Neplacanega narocila ni mogoce obdelati.';
    end if;
    update public.narocila set
      status=coalesce(p_status,status),
      datum_dostave=coalesce(p_datum_dostave,datum_dostave),
      opis_lokacije=coalesce(p_opomba,opis_lokacije)
    where id=p_id;
  elsif p_vir='zahteva' then
    select status into v_staro from public.zahteve_dostave where id=p_id for update;
    if not found then raise exception 'Zahteva ne obstaja.'; end if;
    if v_staro in ('zakljuceno','preklicano') then
      raise exception 'Zakljucene zahteve ni mogoce spreminjati.';
    end if;
    update public.zahteve_dostave set
      status=coalesce(p_status,status),
      datum_dostave=coalesce(p_datum_dostave,datum_dostave),
      opomba=coalesce(p_opomba,opomba)
    where id=p_id;
  else raise exception 'Neznan vir: %',p_vir; end if;
  v_box_status:=case p_status
    -- Potrditev je interna; boxov ne premaknemo.
    when 'pri_stranki' then 'pri_stranki'
    when 'v_skladiscu' then 'v_skladiscu' else null end;
  if v_box_status is not null then
    if p_vir='zahteva' then
      update public.skatle s set status=v_box_status
      where s.id in (select zs.skatla_id from public.zahteve_dostave_skatle zs
        where zs.zahteva_id=p_id);
    else
      update public.skatle s set status=v_box_status
      where s.narocnina_id in (select n.id from public.narocnine n
        where n.narocilo_id=p_id);
    end if;
    get diagnostics v_prizadetih=row_count;
  end if;
  if p_vir='zahteva' and p_status='v_skladiscu'
     and exists (select 1 from public.zahteve_dostave z
       where z.id=p_id and z.opomba ilike 'Vračilo%') then
    update public.skatle s set status='na_zalogi',kupec_id=null,
      narocnina_id=null,tip_storitve=null,lokacija=null,updated_at=now()
    where s.id in (select zs.skatla_id from public.zahteve_dostave_skatle zs
      where zs.zahteva_id=p_id);
  end if;
  begin
    insert into public.dnevnik_dejanj(dejanje,opomba,uporabnik,cas)
    values('status_'||p_vir,p_vir||' #'||p_id||' -> '||coalesce(p_status,'?')||
      case when v_prizadetih>0 then ' ('||v_prizadetih||' skatel)' else '' end,
      coalesce(auth.jwt()->>'email','sistem'),now());
  exception when others then null; end;
  return v_prizadetih;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rb_create_transport_requests(p_box_ids bigint[], p_action text, p_date date, p_time text, p_address text, p_note text DEFAULT NULL::text)
 RETURNS TABLE(zahteva_id bigint, narocilo_id bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_kupec bigint;
  v_count integer;
  v_valid integer;
  v_day date;
  v_days integer:=0;
  v_label text;
  v_order record;
  v_request bigint;
begin
  v_kupec:=public.my_kupec_id();
  if v_kupec is null then raise exception 'Prijava je potrebna.'; end if;
  if p_box_ids is null or cardinality(p_box_ids)=0 then
    raise exception 'Izberi vsaj en box.';
  end if;
  if cardinality(p_box_ids)<>(select count(distinct x) from unnest(p_box_ids) x)
     or array_position(p_box_ids,null) is not null then
    raise exception 'Izbira boxov ni veljavna.';
  end if;
  v_label:=case p_action when 'prevoz_skladisce' then 'Prevoz v skladišče'
    when 'dostava' then 'Dostava k stranki'
    when 'vracilo' then 'Vračilo' end;
  if v_label is null then raise exception 'Vrsta prevoza ni veljavna.'; end if;
  if nullif(btrim(p_address),'') is null or length(p_address)>500
     or length(coalesce(p_note,''))>2000 then
    raise exception 'Naslov ali opomba ni veljavna.';
  end if;
  if p_time is null or p_time !~ '^(10|11|12|13|14):00$' or p_date is null
     or extract(isodow from p_date)>5 then
    raise exception 'Termin ni veljaven.';
  end if;
  v_day:=(now() at time zone 'Europe/Ljubljana')::date;
  while v_days<3 loop
    v_day:=v_day+1;
    if extract(isodow from v_day)<=5 then v_days:=v_days+1; end if;
  end loop;
  if p_date<v_day then raise exception 'Termin mora biti vsaj tri delovne dni vnaprej.'; end if;

  -- Enaka ura za več izvornih naročil iste stranke je ena dostava.
  perform pg_advisory_xact_lock(hashtext(p_date::text||' '||p_time));
  if exists(select 1 from public.zasedeni_termini(p_date) t where left(t,5)=p_time) then
    raise exception 'Izbrani termin je že zaseden.';
  end if;

  -- Zaklenjeni boxi zagotovijo, da se povezava med preverjanjem ne spremeni.
  perform 1 from public.skatle s where s.id=any(p_box_ids) order by s.id for update;
  -- Zaklep boxov zagotovi, da tudi sočasni oddaji ne ustvarita dveh prevozov.
  if exists(select 1 from public.rb_pending_transport_boxes() p where p.skatla_id=any(p_box_ids)) then
    raise exception 'Za enega ali več izbranih boxov je prevoz že naročen. Počakaj na izvedbo ali preklic zahtevka.';
  end if;
  v_count:=cardinality(p_box_ids);
  select count(*) into v_valid
  from public.skatle s
  join public.narocnine n on n.id=s.narocnina_id and n.kupec_id=v_kupec
  join public.narocila o on o.id=n.narocilo_id and o.kupec_id=v_kupec
  where s.id=any(p_box_ids) and s.kupec_id=v_kupec
    and (o.placano=true or o.vir='rocno')
    and o.status not in ('zakljuceno','preklicano')
    and ((p_action='prevoz_skladisce' and s.status='pri_stranki'
          and lower(coalesce(s.tip_storitve,'')) like '%sklad%')
      or (p_action='dostava' and s.status='v_skladiscu'
          and lower(coalesce(s.tip_storitve,'')) like '%sklad%')
      or (p_action='vracilo' and s.status='pri_stranki'
          and lower(coalesce(s.tip_storitve,'')) not like '%sklad%'));
  if v_valid<>v_count then
    raise exception 'Nekateri boxi niso več na voljo za izbrani prevoz. Osveži stran.';
  end if;

  for v_order in
    select n.narocilo_id id, array_agg(s.id order by s.id) box_ids
    from public.skatle s join public.narocnine n on n.id=s.narocnina_id
    where s.id=any(p_box_ids)
    group by n.narocilo_id order by n.narocilo_id
  loop
    insert into public.zahteve_dostave
      (kupec_id,narocilo_id,status,brezplacna,datum_zahteve,datum_dostave,opomba)
    values(v_kupec,v_order.id,'nova',false,now(),p_date,
      v_label||' - Naslov: '||btrim(p_address)||' | Ura: '||p_time||
      case when nullif(btrim(coalesce(p_note,'')),'') is not null
        then ' | '||btrim(p_note) else '' end)
    returning id into v_request;
    insert into public.zahteve_dostave_skatle(zahteva_id,skatla_id)
      select v_request,unnest(v_order.box_ids);
    zahteva_id:=v_request; narocilo_id:=v_order.id;
    return next;
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rb_notify_box_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'rabimbox_service_role' limit 1;
  if v_key is null then raise warning 'Rabimbox: manjka skrivnost za obvestila'; return null; end if;
  for r in
    select k.email, k.ime,
           case when n.status = 'pri_stranki' then 'dostava' else 'prevzem' end as tip,
           case when n.status = 'pri_stranki' and o.status = 'v_skladiscu' then 'vrnitev' else 'prva_dostava' end as faza,
           count(*)::int as st_boksov
    from newtab n join oldtab o on o.id = n.id join public.kupci k on k.id = n.kupec_id
    where (n.status = 'pri_stranki' and o.status = 'v_skladiscu')
       or (n.status = 'v_skladiscu' and o.status = 'pri_stranki')
    group by k.email, k.ime,
             case when n.status = 'pri_stranki' then 'dostava' else 'prevzem' end,
             case when n.status = 'pri_stranki' and o.status = 'v_skladiscu' then 'vrnitev' else 'prva_dostava' end
  loop
    perform net.http_post(
      url := 'https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/poslji-obvestilo',
      headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || v_key,'apikey',v_key),
      body := jsonb_build_object('tip',r.tip,'faza',r.faza,'email',r.email,'ime',r.ime,'st_boksov',r.st_boksov)
    );
  end loop;
  return null;
end; $function$;

-- Popravi le boxe, ki jih je prejšnja potrditev odprtega prevoza nastavila
-- na rezervirano. Smer zahtevka določa stanje pred potrditvijo.
with candidates as (
  select s.id,case
    when z.opomba ilike 'Dostava%' then 'v_skladiscu'
    when z.opomba ilike 'Prevoz v skladišče%' or z.opomba ilike 'Vračilo%' then 'pri_stranki'
    end as source_status
  from public.skatle s
  join public.zahteve_dostave_skatle zs on zs.skatla_id=s.id
  join public.zahteve_dostave z on z.id=zs.zahteva_id
  join public.narocnine n on n.id=s.narocnina_id and n.kupec_id=s.kupec_id
  join public.narocila o on o.id=n.narocilo_id and o.status not in ('zakljuceno','preklicano')
  where s.status='rezervirana' and z.status='caka_dostavo' and s.kupec_id=z.kupec_id
), safe as (
  select id,min(source_status) source_status from candidates
  group by id having count(distinct source_status)=1 and count(*)=count(source_status)
), repaired as (
  update public.skatle s set status=p.source_status from safe p
  where s.id=p.id and s.status='rezervirana' returning s.id,s.barkoda,s.status
)
select 'Popravljeni boxi po prejšnji potrditvi' as rezultat,id,barkoda,status from repaired;

commit;
