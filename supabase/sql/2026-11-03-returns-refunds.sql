-- Vračilo boxov iz zahtevka in izbirno sorazmerno vračilo plačila.
begin;

create table if not exists public.rb_box_refunds (
  id uuid primary key,
  order_id bigint not null references public.narocila(id),
  invoice_id bigint not null references public.racuni(id),
  box_ids bigint[] not null,
  amount_cents integer not null check(amount_cents>=0),
  currency text not null,
  mode text not null check(mode in ('stripe','manual','zero')),
  details jsonb not null,
  status text not null default 'prepared' check(status in ('prepared','submitted','manual','completed')),
  stripe_credit_note_id text unique,
  credit_note_number text,
  stripe_refund_id text,
  provider_status text,
  pdf_url text,
  error text,
  lease_token uuid,
  lease_until timestamptz,
  actor_id uuid,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create table if not exists public.rb_box_refund_items (
  refund_id uuid not null references public.rb_box_refunds(id),
  invoice_id bigint not null references public.racuni(id),
  box_id bigint not null references public.skatle(id),
  primary key(invoice_id,box_id)
);
alter table public.rb_box_refunds enable row level security;
alter table public.rb_box_refund_items enable row level security;
revoke all on public.rb_box_refunds,public.rb_box_refund_items from anon,authenticated;
grant all on public.rb_box_refunds,public.rb_box_refund_items to service_role;
create index if not exists rb_box_refunds_order_idx on public.rb_box_refunds(order_id,created_at desc);

-- Samo pomožna funkcija lastnika; običajen prevoz v skladišče ostane odprt.
create or replace function public.rb_settle_return_requests(p_order bigint)
returns void language sql security definer set search_path=public as $$
  update public.zahteve_dostave z set status='zakljuceno'
  where z.narocilo_id=p_order and z.opomba like 'Vračilo%'
    and z.status not in ('zakljuceno','preklicano')
    and exists(select 1 from public.zahteve_dostave_skatle zs where zs.zahteva_id=z.id)
    and not exists(select 1 from public.zahteve_dostave_skatle zs
      join public.skatle s on s.id=zs.skatla_id
      join public.narocnine n on n.id=s.narocnina_id and n.narocilo_id=p_order
      where zs.zahteva_id=z.id);
$$;
revoke all on function public.rb_settle_return_requests(bigint) from public,anon,authenticated;

create or replace function public.sklad_vrni_boxe(p_narocilo_id bigint,p_skatle bigint[])
returns integer language plpgsql security definer set search_path=public as $$
declare v_order public.narocila%rowtype; v_count integer;
begin
  if not public.is_staff() then raise exception 'Nimate dovoljenja.';end if;
  select * into v_order from public.narocila where id=p_narocilo_id for update;
  if not found or v_order.status in ('zakljuceno','preklicano') then raise exception 'Aktivno naročilo ne obstaja.';end if;
  if coalesce(cardinality(p_skatle),0)=0 or cardinality(p_skatle)>5000
    or array_position(p_skatle,null) is not null
    or cardinality(p_skatle)<>(select count(distinct x) from unnest(p_skatle)x) then
    raise exception 'Izberite veljavne boxe.';
  end if;
  perform 1 from public.skatle where id=any(p_skatle) order by id for update;
  if (select count(*) from public.skatle s join public.narocnine n on n.id=s.narocnina_id
      where s.id=any(p_skatle) and n.narocilo_id=p_narocilo_id
        and s.kupec_id=v_order.kupec_id and s.status in ('pri_stranki','v_skladiscu'))<>cardinality(p_skatle) then
    raise exception 'Izbrani boxi ne pripadajo aktivnemu naročilu.';
  end if;
  update public.skatle set status='na_zalogi',kupec_id=null,narocnina_id=null,
    tip_storitve=null,lokacija=null,updated_at=now() where id=any(p_skatle);
  get diagnostics v_count=row_count;
  perform public.rb_settle_return_requests(p_narocilo_id);
  return v_count;
end;$$;
revoke all on function public.sklad_vrni_boxe(bigint,bigint[]) from public,anon;
grant execute on function public.sklad_vrni_boxe(bigint,bigint[]) to authenticated;

create or replace function public.sklad_predogled_vracila_zahtevka(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare z public.zahteve_dostave%rowtype; v_all integer; v_return integer;
begin
  if not public.is_staff() then raise exception 'Nimate dovoljenja.';end if;
  select * into z from public.zahteve_dostave where id=p_id;
  if not found or z.narocilo_id is null or split_part(coalesce(z.opomba,''),' - ',1)<>'Vračilo in zaključek naročila' then
    raise exception 'Zahtevek za vračilo in zaključek ne obstaja.';
  end if;
  if z.status='preklicano' then raise exception 'Zahtevek je preklican.';end if;
  select count(*) into v_all from public.skatle s join public.narocnine n on n.id=s.narocnina_id where n.narocilo_id=z.narocilo_id;
  select count(*) into v_return from public.skatle s join public.narocnine n on n.id=s.narocnina_id
    join public.zahteve_dostave_skatle zs on zs.skatla_id=s.id and zs.zahteva_id=z.id
    where n.narocilo_id=z.narocilo_id and s.kupec_id=z.kupec_id and s.status in ('pri_stranki','v_skladiscu');
  return jsonb_build_object('order_id',z.narocilo_id,'return_count',v_return,'remaining_count',v_all-v_return,
    'order_ref',(select stevilka from public.narocila where id=z.narocilo_id));
end;$$;
revoke all on function public.sklad_predogled_vracila_zahtevka(bigint) from public,anon;
grant execute on function public.sklad_predogled_vracila_zahtevka(bigint) to authenticated;

create or replace function public.sklad_vrni_zahtevek(p_id bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare z public.zahteve_dostave%rowtype; o public.narocila%rowtype;
  v_order bigint; v_boxes bigint[]; v_count integer:=0; v_remaining integer; v_closed boolean:=false;
begin
  if not public.is_staff() then raise exception 'Nimate dovoljenja.';end if;
  select narocilo_id into v_order from public.zahteve_dostave where id=p_id;
  select * into o from public.narocila where id=v_order for update;
  if not found then raise exception 'Povezano naročilo ne obstaja.';end if;
  select * into z from public.zahteve_dostave where id=p_id for update;
  if z.narocilo_id is distinct from o.id or z.kupec_id is distinct from o.kupec_id or split_part(coalesce(z.opomba,''),' - ',1)<>'Vračilo in zaključek naročila'
    or z.status='preklicano' or o.status='preklicano' then raise exception 'Zahtevka ni mogoče obdelati.';end if;
  select array_agg(s.id order by s.id) into v_boxes from public.skatle s
    join public.narocnine n on n.id=s.narocnina_id and n.narocilo_id=o.id
    join public.zahteve_dostave_skatle zs on zs.skatla_id=s.id and zs.zahteva_id=z.id
    where s.kupec_id=z.kupec_id and s.status in ('pri_stranki','v_skladiscu');
  if coalesce(cardinality(v_boxes),0)>0 then v_count:=public.sklad_vrni_boxe(o.id,v_boxes);end if;
  select count(*) into v_remaining from public.skatle s join public.narocnine n on n.id=s.narocnina_id where n.narocilo_id=o.id;
  if v_remaining=0 and o.status not in ('zakljuceno','preklicano') then
    perform public.sklad_zakljuci_narocilo(o.id,null);v_closed:=true;
  end if;
  update public.zahteve_dostave set status='zakljuceno' where id=z.id and status<>'zakljuceno';
  return jsonb_build_object('order_id',o.id,'returned_count',v_count,'remaining_count',v_remaining,
    'order_closed',v_closed,'already_processed',v_count=0 and not v_closed);
end;$$;
revoke all on function public.sklad_vrni_zahtevek(bigint) from public,anon;
grant execute on function public.sklad_vrni_zahtevek(bigint) to authenticated;

create or replace function public.rb_box_return_quote(p_order bigint,p_boxes bigint[])
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare o public.narocila%rowtype;n public.narocnine%rowtype;r public.racuni%rowtype;
  v_count integer;v_days integer;v_cents integer;v_reserved integer;v_codes text[];
begin
  if coalesce(auth.role(),'')<>'service_role' and not exists(select 1 from public.osebje where user_id=auth.uid() and vloga='admin') then
    raise exception 'Vračilo denarja lahko ureja samo administrator.';end if;
  if coalesce(cardinality(p_boxes),0)=0 or cardinality(p_boxes)>5000 or array_position(p_boxes,null) is not null
    or cardinality(p_boxes)<>(select count(distinct x) from unnest(p_boxes)x) then raise exception 'Izberite veljavne boxe.';end if;
  select * into o from public.narocila where id=p_order;
  if not found or o.status in ('zakljuceno','preklicano') then raise exception 'Aktivno naročilo ne obstaja.';end if;
  select * into n from public.narocnine where narocilo_id=o.id and status='aktivna' order by id desc limit 1;
  if not found or n.datum_od is null or n.datum_do is null or n.datum_do-n.datum_od<>30 or coalesce(n.st_boxov,0)<=0 then raise exception '30-dnevno obračunsko obdobje ni veljavno.';end if;
  select count(*),array_agg(s.barkoda order by s.id) into v_count,v_codes from public.skatle s
    where s.id=any(p_boxes) and s.narocnina_id=n.id and s.kupec_id=o.kupec_id and s.status in ('pri_stranki','v_skladiscu');
  if v_count<>cardinality(p_boxes) then raise exception 'Izbrani boxi ne pripadajo aktivnemu naročilu.';end if;
  select * into r from public.racuni where narocilo_id=o.id and placano=true
    and obdobje_od=n.datum_od and obdobje_do=n.datum_do order by id desc limit 1;
  if not found then raise exception 'Za trenutno obdobje ni plačanega računa. Samodejno vračilo ni mogoče.';end if;
  if upper(coalesce(r.valuta,'EUR'))<>'EUR' or r.znesek is null or r.znesek<0 then raise exception 'Valuta ali znesek računa ni veljaven.';end if;
  if exists(select 1 from public.rb_box_refund_items where invoice_id=r.id and box_id=any(p_boxes)) then
    raise exception 'Za enega od izbranih boxov je vračilo tega računa že evidentirano.';end if;
  v_days:=greatest(0,least(30,n.datum_do-greatest((now() at time zone 'Europe/Ljubljana')::date,n.datum_od)));
  select coalesce(sum(amount_cents),0) into v_reserved from public.rb_box_refunds where invoice_id=r.id;
  v_cents:=least(round(r.znesek*100*v_count*v_days/(30*n.st_boxov))::integer,greatest(0,round(r.znesek*100)::integer-v_reserved));
  return jsonb_build_object('order_id',o.id,'order_ref',o.stevilka,'invoice_id',r.id,'invoice_number',coalesce(r.stripe_stevilka,r.stevilka),
    'stripe_invoice_id',r.stripe_invoice_id,'stripe_customer_id',n.stripe_customer_id,'stripe_subscription_id',n.stripe_subscription_id,
    'is_test',coalesce(o.is_test,false),'box_ids',p_boxes,'box_codes',v_codes,'box_count',v_count,
    'paid_box_count',n.st_boxov,'period_start',n.datum_od,'period_end',n.datum_do,'unused_days',v_days,'amount_cents',v_cents,'currency','eur',
    'mode',case when v_cents=0 then 'zero' when r.stripe_invoice_id is not null then 'stripe' else 'manual' end);
end;$$;
revoke all on function public.rb_box_return_quote(bigint,bigint[]) from public,anon;
grant execute on function public.rb_box_return_quote(bigint,bigint[]) to authenticated,service_role;

create or replace function public.rb_prepare_box_refund(p_order bigint,p_boxes bigint[],p_key uuid,p_expected integer,p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.rb_box_refunds%rowtype;q jsonb;v_sorted bigint[];
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Ni dovoljeno.';end if;
  if p_key is null then raise exception 'Manjka ključ vračila.';end if;
  perform 1 from public.narocila where id=p_order for update;
  select array_agg(x order by x) into v_sorted from unnest(p_boxes)x;
  select * into v_existing from public.rb_box_refunds where id=p_key;
  if found then
    if v_existing.order_id<>p_order or v_existing.box_ids is distinct from v_sorted then raise exception 'Ključ vračila je že uporabljen za drugo izbiro.';end if;
    return to_jsonb(v_existing);
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
  perform public.rb_settle_return_requests(p_order);
  return (select to_jsonb(f) from public.rb_box_refunds f where id=p_key);
end;$$;
revoke all on function public.rb_prepare_box_refund(bigint,bigint[],uuid,integer,uuid) from public,anon,authenticated;
grant execute on function public.rb_prepare_box_refund(bigint,bigint[],uuid,integer,uuid) to service_role;

create or replace function public.rb_claim_box_refund(p_id uuid,p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare f public.rb_box_refunds%rowtype;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Ni dovoljeno.';end if;
  if p_token is null then raise exception 'Manjka ključ obdelave.';end if;
  select * into f from public.rb_box_refunds where id=p_id for update;
  if not found then raise exception 'Vračilo ne obstaja.';end if;
  if f.status<>'prepared' then return to_jsonb(f);end if;
  if f.lease_until>now() then raise exception 'Vračilo se že obdeluje. Poskusite čez dve minuti.';end if;
  update public.rb_box_refunds set lease_token=p_token,lease_until=now()+interval '2 minutes',error=null where id=p_id returning * into f;
  return to_jsonb(f);
end;$$;
revoke all on function public.rb_claim_box_refund(uuid,uuid) from public,anon,authenticated;
grant execute on function public.rb_claim_box_refund(uuid,uuid) to service_role;

commit;
