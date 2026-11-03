-- Obstoječi gumb: razlika med paketoma za odvečne boxe ob prvi dostavi.
begin;

create or replace function public.rb_box_return_quote(p_order bigint,p_boxes bigint[])
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare o public.narocila%rowtype;n public.narocnine%rowtype;r public.racuni%rowtype;
  v_count integer;v_all integer;v_kept integer;v_before integer;v_after integer;v_cents integer;v_reserved integer;v_codes text[];
begin
  if coalesce(auth.role(),'')<>'service_role' and not exists(select 1 from public.osebje where user_id=auth.uid() and vloga='admin') then
    raise exception 'Vračilo denarja lahko ureja samo administrator.';end if;
  if coalesce(cardinality(p_boxes),0)=0 or cardinality(p_boxes)>5000 or array_position(p_boxes,null) is not null
    or cardinality(p_boxes)<>(select count(distinct x) from unnest(p_boxes)x) then raise exception 'Izberite veljavne boxe.';end if;
  select * into o from public.narocila where id=p_order;
  if not found or o.status in ('zakljuceno','preklicano') then raise exception 'Aktivno naročilo ne obstaja.';end if;
  select * into n from public.narocnine where narocilo_id=o.id and status='aktivna' order by id desc limit 1;
  if not found or n.datum_od is null or n.datum_do is null or n.datum_do-n.datum_od<>30 or coalesce(n.st_boxov,0)<=0 then raise exception 'Začetno 30-dnevno obdobje ni veljavno.';end if;
  if o.st_boxov_dejansko is null or o.prevzem_cas is null or n.datum_od is distinct from o.datum_dostave
    or (now() at time zone 'Europe/Ljubljana')::date>=n.datum_do then
    raise exception 'Vračilo je mogoče samo za odvečne boxe ob prvi dostavi, po potrditvi prevzema.';end if;
  select count(*) into v_all from public.skatle where narocnina_id=n.id;
  if v_all<>n.st_boxov or v_all<>o.st_boxov_dejansko then raise exception 'Po prvem prevzemu so bili boxi že vrnjeni. Poznejša vračila ne omogočajo vračila denarja.';end if;
  select count(*),array_agg(s.barkoda order by s.id) into v_count,v_codes from public.skatle s
    where s.id=any(p_boxes) and s.narocnina_id=n.id and s.kupec_id=o.kupec_id and s.status in ('pri_stranki','v_skladiscu');
  if v_count<>cardinality(p_boxes) then raise exception 'Izbrani boxi ne pripadajo aktivnemu naročilu.';end if;
  if exists(select 1 from public.zahteve_dostave_skatle zs join public.zahteve_dostave z on z.id=zs.zahteva_id
      where zs.skatla_id=any(p_boxes) and z.narocilo_id=o.id and z.status<>'preklicano') then
    raise exception 'Za izbrane boxe je bil že naročen prevoz. Gumb za vračilo denarja velja samo za neuporabljene odvečne boxe ob prvi dostavi.';end if;
  select * into r from public.racuni where narocilo_id=o.id and placano=true
    and obdobje_od=n.datum_od and obdobje_do=n.datum_do order by id limit 1;
  if not found or exists(select 1 from public.racuni where narocilo_id=o.id and placano=true and obdobje_od>r.obdobje_od) then
    raise exception 'Za prvo obdobje ni ustreznega plačanega računa ali je bilo naročilo že obnovljeno.';end if;
  if upper(coalesce(r.valuta,'EUR'))<>'EUR' or r.znesek is null or r.znesek<0 then raise exception 'Valuta ali znesek računa ni veljaven.';end if;
  if exists(select 1 from public.rb_box_refund_items where invoice_id=r.id and box_id=any(p_boxes)) then
    raise exception 'Za enega od izbranih boxov je vračilo tega računa že evidentirano.';end if;
  v_kept:=v_all-v_count;
  v_before:=round(public.rb_cena(o.tip,v_all)*100)::integer;
  v_after:=round(public.rb_cena(o.tip,v_kept)*100)::integer;
  if v_before<=0 or (v_kept>0 and v_after<=0) then raise exception 'Za izbrano količino ni veljavnega paketa.';end if;
  if v_after>v_before then raise exception 'Paket za % boxov je dražji od prvotnega paketa. Pred spremembo uredite doplačilo ročno.',v_kept;end if;
  select coalesce(sum(amount_cents),0) into v_reserved from public.rb_box_refunds where invoice_id=r.id;
  v_cents:=v_before-v_after;
  if v_cents>round(r.znesek*100)::integer-v_reserved then raise exception 'Razlika paketov presega preostali plačani znesek računa. Potreben je ročni pregled.';end if;
  return jsonb_build_object('kind','initial_delivery','order_id',o.id,'order_ref',o.stevilka,'subscription_id',n.id,
    'invoice_id',r.id,'invoice_number',coalesce(r.stripe_stevilka,r.stevilka),'stripe_invoice_id',r.stripe_invoice_id,
    'stripe_customer_id',n.stripe_customer_id,'stripe_subscription_id',n.stripe_subscription_id,
    'is_test',coalesce(o.is_test,false),'box_ids',p_boxes,'box_codes',v_codes,'box_count',v_count,
    'ordered_box_count',v_all,'accepted_box_count',v_kept,'package_before_cents',v_before,'package_after_cents',v_after,
    'period_start',n.datum_od,'period_end',n.datum_do,'amount_cents',v_cents,'currency','eur',
    'mode',case when v_cents=0 then 'zero' when r.stripe_invoice_id is not null then 'stripe' else 'manual' end);
end;$$;

create or replace function public.rb_prepare_box_refund(p_order bigint,p_boxes bigint[],p_key uuid,p_expected integer,p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare f public.rb_box_refunds%rowtype;q jsonb;v_sorted bigint[];
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Ni dovoljeno.';end if;
  if p_key is null then raise exception 'Manjka ključ vračila.';end if;
  perform 1 from public.narocila where id=p_order for update;
  select array_agg(x order by x) into v_sorted from unnest(p_boxes)x;
  select * into f from public.rb_box_refunds where id=p_key;
  if found then
    if f.order_id<>p_order or f.box_ids is distinct from v_sorted or f.details->>'kind' is distinct from 'initial_delivery' then raise exception 'Ključ vračila je že uporabljen za drugo izbiro.';end if;
    return to_jsonb(f);
  end if;
  if exists(select 1 from public.rb_box_refunds where order_id=p_order and status='prepared') then
    raise exception 'To naročilo ima nedokončano vračilo. Najprej ponovite obstoječe vračilo.';end if;
  perform 1 from public.skatle where id=any(p_boxes) order by id for update;
  q:=public.rb_box_return_quote(p_order,p_boxes);
  if (q->>'amount_cents')::integer is distinct from p_expected then raise exception 'Znesek se je spremenil. Ponovno odprite predogled.';end if;
  insert into public.rb_box_refunds(id,order_id,invoice_id,box_ids,amount_cents,currency,mode,details,actor_id)
    values(p_key,p_order,(q->>'invoice_id')::bigint,v_sorted,p_expected,q->>'currency',q->>'mode',q,p_actor);
  insert into public.rb_box_refund_items(refund_id,invoice_id,box_id) select p_key,(q->>'invoice_id')::bigint,unnest(v_sorted);
  update public.skatle set status='na_zalogi',kupec_id=null,narocnina_id=null,tip_storitve=null,lokacija=null,updated_at=now() where id=any(v_sorted);
  update public.narocnine set st_boxov=(q->>'accepted_box_count')::integer,cena_mesecna=(q->>'package_after_cents')::numeric/100,
    naslednje_st_boxov=null,naslednja_cena=null,sprememba_od=null,updated_at=now() where id=(q->>'subscription_id')::bigint;
  update public.narocila set st_boxov_dejansko=(q->>'accepted_box_count')::integer,
    cena_koncna=(q->>'package_after_cents')::numeric/100,znesek_vracila=coalesce(znesek_vracila,0)+p_expected::numeric/100 where id=p_order;
  perform public.rb_settle_return_requests(p_order);
  return (select to_jsonb(r) from public.rb_box_refunds r where r.id=p_key);
end;$$;

commit;
