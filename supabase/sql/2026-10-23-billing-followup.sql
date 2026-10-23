-- Dopolnitev: prej prejeti dogodek ne sme zavrteti obdobja nazaj.
begin;
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


commit;
