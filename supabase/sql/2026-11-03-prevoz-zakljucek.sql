-- Ločen zahtevek za vračilo izbranih boxov in ročni zaključek naročila.
-- Naročilo ostane odprto do dejanskega zaključka v skladiščni aplikaciji.
begin;

create or replace function public.rb_create_transport_requests(
  p_box_ids bigint[], p_action text, p_date date, p_time text,
  p_address text, p_note text default null
) returns table(zahteva_id bigint, narocilo_id bigint)
language plpgsql security definer set search_path=public as $$
declare
  v_kupec bigint; v_count integer; v_valid integer;
  v_day date; v_days integer:=0; v_label text;
  v_order record; v_request bigint;
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
  v_label:=case p_action
    when 'prevoz_skladisce' then 'Prevoz v skladišče'
    when 'dostava' then 'Dostava k stranki'
    when 'vracilo' then 'Vračilo'
    when 'vracilo_zakljucek' then 'Vračilo in zaključek naročila' end;
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

  perform pg_advisory_xact_lock(hashtext(p_date::text||' '||p_time));
  if exists(select 1 from public.zasedeni_termini(p_date) t where left(t,5)=p_time) then
    raise exception 'Izbrani termin je že zaseden.';
  end if;
  perform 1 from public.skatle s where s.id=any(p_box_ids) order by s.id for update;
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
          and lower(coalesce(s.tip_storitve,'')) not like '%sklad%')
      or (p_action='vracilo_zakljucek' and s.status='pri_stranki'));
  if v_valid<>v_count then
    raise exception 'Nekateri boxi niso več na voljo za izbrani prevoz. Osveži stran.';
  end if;

  -- Dovoljen je tudi del boxov. Vsako izvorno naročilo dobi svoj zahtevek.
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

commit;
