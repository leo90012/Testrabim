-- Količina in cena v podrobnostih veljata za isto trenutno obračunsko obdobje.
create or replace function public.rb_billing_order_details(p_id bigint) returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('vir',o.vir,'nacin_placila',o.nacin_placila,'cena',coalesce(n.cena_mesecna,public.rb_cena(o.tip,o.st_boxov)),
    'tip',o.tip,'st_boxov',coalesce(n.st_boxov,o.st_boxov),'datum_od',n.datum_od,'datum_do',n.datum_do,'datum_narocila',o.created_at,'auto_renew',coalesce(n.auto_renew,false),'billing_status',n.billing_status,'is_test',o.is_test,
    'placano',o.placano,'cancel_requested_at',n.cancel_requested_at)
  from public.narocila o left join lateral(select * from public.narocnine where narocilo_id=o.id order by id desc limit 1)n on true
  where o.id=p_id and (public.is_staff() or o.kupec_id=public.my_kupec_id());
$$;
revoke all on function public.rb_billing_order_details(bigint) from public,anon;
grant execute on function public.rb_billing_order_details(bigint) to authenticated;
