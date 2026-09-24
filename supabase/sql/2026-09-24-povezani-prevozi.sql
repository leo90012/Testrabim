-- Vsak prevoz pripada prvotnemu naročilu. Več naročil v eni izbiri
-- ustvari več zahtevkov v eni transakciji.
alter table public.zahteve_dostave
  add column if not exists narocilo_id bigint references public.narocila(id) on delete set null;
create index if not exists zahteve_dostave_narocilo_id_idx
  on public.zahteve_dostave(narocilo_id);

-- Stari zahtevki: najprej povezava prek boxov, ki so še v naročnini.
with povezave as (
  select z.id, min(n.narocilo_id) narocilo_id
  from public.zahteve_dostave z
  join public.zahteve_dostave_skatle zs on zs.zahteva_id=z.id
  join public.skatle s on s.id=zs.skatla_id and s.kupec_id=z.kupec_id
  join public.narocnine n on n.id=s.narocnina_id and n.kupec_id=z.kupec_id
  where z.narocilo_id is null and n.narocilo_id is not null
  group by z.id having count(distinct n.narocilo_id)=1
)
update public.zahteve_dostave z set narocilo_id=p.narocilo_id
from povezave p where p.id=z.id;

-- Pri že vrnjenih boxih povezave do naročnine ni več. Poveži samo,
-- če se število boxov ujema z natanko enim prejšnjim naročilom stranke.
with velikosti as (
  select z.id, z.kupec_id, z.datum_zahteve,
    count(zs.skatla_id)::integer st_boxov
  from public.zahteve_dostave z
  join public.zahteve_dostave_skatle zs on zs.zahteva_id=z.id
  where z.narocilo_id is null
  group by z.id
), kandidati as (
  select v.id, min(o.id) narocilo_id
  from velikosti v join public.narocila o
    on o.kupec_id=v.kupec_id and o.st_boxov=v.st_boxov
    and o.created_at<=v.datum_zahteve
    and (o.placano=true or o.vir='rocno')
  group by v.id having count(*)=1
)
update public.zahteve_dostave z set narocilo_id=k.narocilo_id
from kandidati k where k.id=z.id;

update public.zahteve_dostave z set status=
  case when o.status='preklicano' then 'preklicano' else 'zakljuceno' end
from public.narocila o
where o.id=z.narocilo_id and o.status in ('zakljuceno','preklicano')
  and z.status not in ('zakljuceno','preklicano');

create or replace function public.rb_close_linked_transport()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status in ('zakljuceno','preklicano')
     and new.status is distinct from old.status then
    update public.zahteve_dostave
      set status=case when new.status='preklicano' then 'preklicano' else 'zakljuceno' end
      where narocilo_id=new.id and status not in ('zakljuceno','preklicano');
  end if;
  return new;
end;
$$;
drop trigger if exists trg_close_linked_transport on public.narocila;
create trigger trg_close_linked_transport after update of status on public.narocila
  for each row execute function public.rb_close_linked_transport();

-- Neposredni vpisi iz brskalnika lahko ustvarijo nepovezane ali delne
-- zahtevke. Od zdaj jih ustvari le funkcija spodaj.
drop policy if exists zd_insert_own on public.zahteve_dostave;
drop policy if exists zd_update_own on public.zahteve_dostave;
drop policy if exists zds_insert_own on public.zahteve_dostave_skatle;

create or replace function public.rb_create_transport_requests(
  p_box_ids bigint[], p_action text, p_date date,
  p_time text, p_address text, p_note text default null
) returns table(zahteva_id bigint,narocilo_id bigint)
language plpgsql security definer set search_path=public as $$
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
  perform 1 from public.skatle s where s.id=any(p_box_ids) for update;
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
$$;
revoke all on function public.rb_create_transport_requests(bigint[],text,date,text,text,text)
  from public,anon,authenticated;
grant execute on function public.rb_create_transport_requests(bigint[],text,date,text,text,text)
  to authenticated;

-- Skladiščni seznam dobi številko povezanega naročila tudi za zahtevke.
create or replace function public.sklad_zahteve(
  p_offset integer default 0, p_limit integer default 1000
) returns table (
  id bigint, vir text, stevilka text, vrsta text, status text, placano boolean,
  kupec_id bigint, kupec text, stevilka_stranke text, kupec_email text,
  telefon text, st_boxov integer, naslov text, postna_stevilka text,
  mesto text, datum_dostave date, cas_dostave text, opomba text,
  stopnice boolean, pomoc_polnjenje boolean, ustvarjeno timestamptz,
  st_boxov_dejansko integer, znesek_vracila numeric
) language sql stable security definer set search_path = public as $$
  with zdruzeno as (
    select n.id, 'narocilo'::text vir, n.stevilka, coalesce(n.paket,n.tip) vrsta,
      n.status,n.placano,n.kupec_id,
      nullif(btrim(coalesce(n.ime,'')||' '||coalesce(n.priimek,'')),'') kupec,
      k.stevilka_stranke,n.email kupec_email,n.telefon,n.st_boxov::int,
      nullif(btrim(coalesce(n.naslov,'')||
        case when coalesce(n.enota,'')<>'' then ', enota '||n.enota else '' end),'') naslov,
      n.postna_stevilka,n.mesto,n.datum_dostave::date,n.cas_dostave::text,
      n.opis_lokacije opomba,n.stopnice,n.pomoc_polnjenje,n.created_at ustvarjeno,
      n.st_boxov_dejansko,n.znesek_vracila
    from public.narocila n left join public.kupci k on k.id=n.kupec_id
    where n.placano=true or n.vir='rocno'
    union all
    select z.id,'zahteva'::text,o.stevilka,
      coalesce(nullif(split_part(z.opomba,' - ',1),''),'Zahteva'),
      z.status,null::boolean,z.kupec_id,
      nullif(btrim(coalesce(k.ime,'')||' '||coalesce(k.priimek,'')),''),
      k.stevilka_stranke,k.email,k.telefon,
      (select count(*)::int from public.zahteve_dostave_skatle zs where zs.zahteva_id=z.id),
      nullif(btrim(coalesce(k.naslov,'')),''),k.postna_stevilka,k.kraj,
      z.datum_dostave::date,null::text,z.opomba,null::boolean,null::boolean,
      z.datum_zahteve,null::int,null::numeric
    from public.zahteve_dostave z
    left join public.kupci k on k.id=z.kupec_id
    left join public.narocila o on o.id=z.narocilo_id
  )
  select * from zdruzeno
  where public.is_staff() and datum_dostave is not null
  order by (status in ('zakljuceno','preklicano')),(status<>'nova'),
    datum_dostave,ustvarjeno desc
  offset greatest(coalesce(p_offset,0),0)
  limit least(coalesce(p_limit,1000),5000);
$$;
