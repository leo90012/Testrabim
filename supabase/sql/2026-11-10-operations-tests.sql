begin;
do $test$
declare customer_id bigint;customer_email text;admin_id uuid;staff_claims text;customer_claims text;
  o bigint;n bigint;orders bigint[]:=array[]::bigint[];subs bigint[]:=array[]::bigint[];ids bigint[];
  i integer;rejected boolean;active boolean;count_boxes integer;day date:=current_date+1000;req bigint;result jsonb;
begin
  select id,email into strict customer_id,customer_email from public.kupci where email is not null order by id limit 1;
  select user_id into strict admin_id from public.osebje where vloga='admin' order by user_id limit 1;
  staff_claims:=jsonb_build_object('sub',admin_id,'email','admin@rabimbox.si','role','authenticated')::text;
  customer_claims:=jsonb_build_object('sub',gen_random_uuid(),'email',customer_email,'role','authenticated')::text;
  perform set_config('request.jwt.claims',staff_claims,true);
  for i in 1..3 loop
    insert into public.narocila(is_test,vir,placano,tip,st_boxov,datum_dostave,status,email,ime,priimek,stevilka,naslov,mesto)
      values(true,'rocno',true,case when i=2 then 'izposoja' else 'skladiscenje' end,3,current_date,'caka_dostavo',customer_email,'QA','Operacije','QA-OPS-'||gen_random_uuid(),'Testna 1','Ljubljana') returning id into o;
    select id into strict n from public.narocnine where narocilo_id=o;
    orders:=array_append(orders,o);subs:=array_append(subs,n);
    select array_agg(id order by id) into ids from(select id from public.skatle where status='na_zalogi' and kupec_id is null order by id limit 3 for update)x;
    if cardinality(ids)<>3 then raise exception 'TEST: ni prostih boxov';end if;
    update public.skatle set narocnina_id=n,kupec_id=customer_id,tip_storitve=case when i=2 then 'izposoja' else 'skladiscenje' end,status=case when i=2 then 'rezervirana' else 'pri_stranki' end where id=any(ids);
    if i<>2 then update public.narocila set status='pri_stranki',st_boxov_dejansko=3,prevzem_cas=now() where id=o;end if;
  end loop;
  select aktivno,st_boxov into active,count_boxes from public.sklad_stanje_narocil(array[orders[2]]);
  if not active or count_boxes<>3 then raise exception 'TEST: rezervirani boxi niso aktivno naročilo';end if;
  if has_function_privilege('authenticated','public.rb_create_transport_requests_core(bigint[],text,date,text,text,text)','EXECUTE')
    or has_function_privilege('authenticated','public.rb_close_empty_order(bigint,boolean)','EXECUTE') then raise exception 'TEST: zasebna funkcija izpostavljena';end if;
  perform set_config('request.jwt.claims',customer_claims,true);
  rejected:=false;begin perform public.sklad_stanje_narocil(array[orders[1]]);exception when others then if sqlerrm='Nimate dovoljenja.' then rejected:=true;else raise;end if;end;
  if not rejected then raise exception 'TEST: stranka dostopa do skladiščnih statusov';end if;
  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[3];
  for i in 1..3 loop
    rejected:=false;begin perform public.rb_create_transport_requests(array[ids[1]],'vracilo_zakljucek',day,'10:00','Testna 1',null,case i when 1 then null when 2 then 'slovenija' else 'tujina' end,'Ljubljana');
      exception when others then if sqlerrm like 'Naročilo prevzemov preko spleta je možno samo po Ljubljani%' then rejected:=true;else raise;end if;end;
    if not rejected then raise exception 'TEST: neveljavno območje sprejeto';end if;
  end loop;
  while extract(isodow from day)>5 or exists(select 1 from public.zasedeni_termini(day)) loop day:=day+1;end loop;
  select zahteva_id into strict req from public.rb_create_transport_requests(ids,'vracilo_zakljucek',day,'10:00','Testna 1',null,'ljubljana','Ljubljana');
  if(select opomba from public.zahteve_dostave where id=req) not like '%Naslov: Testna 1, Ljubljana%' then raise exception 'TEST: kraj se ne shrani v zahtevek';end if;
  perform set_config('request.jwt.claims',staff_claims,true);
  result:=public.sklad_vrni_zahtevek(req);
  if not(result->>'order_closed')::boolean then raise exception 'TEST: zaključni prevoz ni zaključil naročila';end if;
  set constraints rb_close_order_without_boxes immediate;
  if(select status from public.narocila where id=orders[3])<>'zakljuceno' then raise exception 'TEST: zaključni prevoz ni zaprt';end if;
  set constraints rb_close_order_without_boxes deferred;

  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[1];
  perform public.sklad_vrni_boxe(orders[1],array[ids[1]]);
  set constraints rb_close_order_without_boxes immediate;
  select aktivno,st_boxov into active,count_boxes from public.sklad_stanje_narocil(array[orders[1]]);
  if not active or count_boxes<>2 or(select status from public.narocila where id=orders[1])='zakljuceno' then raise exception 'TEST: delno vračilo je zaprlo naročilo';end if;
  if(select cena_mesecna from public.narocnine where id=subs[1])<>14.70 or(select naslednja_cena from public.narocnine where id=subs[1])<>9.80 then raise exception 'TEST: delno vračilo spremeni že plačano ceno';end if;
  set constraints rb_close_order_without_boxes deferred;
  perform public.sklad_vrni_boxe(orders[1],ids[2:3]);
  set constraints rb_close_order_without_boxes immediate;
  select aktivno,st_boxov into active,count_boxes from public.sklad_stanje_narocil(array[orders[1]]);
  if active or count_boxes<>0 or(select status from public.narocila where id=orders[1])<>'zakljuceno'
    or(select status from public.narocnine where id=subs[1])<>'zakljucena' or(select auto_renew from public.narocnine where id=subs[1]) then raise exception 'TEST: zadnji box ni zaključil najema';end if;
  if public.rb_close_empty_order(orders[1],false) then raise exception 'TEST: ponovljeni zaključek ni idempotenten';end if;
  set constraints rb_close_order_without_boxes deferred;
  -- Prvi prevzem z nič boxi se dokonča kot preklic v isti transakciji.
  update public.skatle set status='na_zalogi',kupec_id=null,narocnina_id=null,tip_storitve=null where narocnina_id=subs[2];
  update public.narocila set status='preklicano',st_boxov_dejansko=0 where id=orders[2];
  update public.narocnine set status='preklicana' where id=subs[2];
  set constraints rb_close_order_without_boxes immediate;
  if(select status from public.narocila where id=orders[2])<>'preklicano' then raise exception 'TEST: odloženi zaključek je posegel v preklic prve dostave';end if;
  rejected:=false;begin perform public.rb_box_return_quote(orders[1],array[ids[1]]);exception when others then if sqlerrm like 'Vračilo denarja uredite ročno.%' then rejected:=true;else raise;end if;end;
  if not rejected then raise exception 'TEST: stari finančni predogled je omogočen';end if;
end$test$;
select 'PASS: local transport validation, reserved/partial/full usage, automatic closure, cancellation and disabled payouts' as result;
rollback;
