-- Izolirani finančni preizkusi: vse spremembe se povrnejo.
begin;
do $test$
declare customer_id bigint;customer_email text;admin_id uuid;claims text;
  orders bigint[]:=array[]::bigint[];subs bigint[]:=array[]::bigint[];ids bigint[];
  o bigint;n bigint;qty integer;tip text;price numeric;q jsonb;r jsonb;key1 uuid:=gen_random_uuid();key2 uuid:=gen_random_uuid();
  failed boolean;i integer;req bigint;
begin
  select k.id,k.email into strict customer_id,customer_email from public.kupci k join public.narocila o on o.kupec_id=k.id where o.stevilka='TEST-20261023-MATIC';
  select user_id into strict admin_id from public.osebje where vloga='admin' order by user_id limit 1;
  claims:=jsonb_build_object('sub',admin_id,'email','admin@rabimbox.si','role','authenticated')::text;
  perform set_config('request.jwt.claims',claims,true);
  for i in 1..7 loop
    qty:=case i when 1 then 40 when 2 then 12 when 3 then 40 when 4 then 40 when 7 then 26 else 3 end;
    tip:=case when i in(3,4) then 'izposoja' else 'skladiscenje' end;
    price:=public.rb_cena(tip,qty);
    insert into public.narocila(is_test,vir,placano,tip,st_boxov,datum_dostave,status,email,ime,priimek,stevilka,naslov,mesto)
      values(true,'rocno',true,tip,qty,current_date-10,'caka_dostavo',customer_email,'QA','Paket','QA-INITIAL-'||gen_random_uuid(),'Testni naslov','Ljubljana') returning id into o;
    select id into strict n from public.narocnine where narocilo_id=o;
    orders:=array_append(orders,o);subs:=array_append(subs,n);
    select array_agg(id order by id) into ids from(select id from public.skatle where status='na_zalogi' and kupec_id is null order by id limit qty for update)x;
    if cardinality(ids)<>qty then raise exception 'TEST: premalo prostih boxov';end if;
    update public.skatle set kupec_id=customer_id,narocnina_id=n,tip_storitve=tip,status='pri_stranki' where id=any(ids);
    update public.narocila set st_boxov_dejansko=qty,prevzem_cas=now(),cena_prvotna=price,cena_koncna=price,znesek_vracila=0,status='pri_stranki' where id=o;
    insert into public.racuni(narocilo_id,kupec_id,stevilka,placano,status,znesek,osnova,ddv,valuta,obdobje_od,obdobje_do,is_test)
      values(o,customer_id,'QA-INVOICE-'||gen_random_uuid(),true,'placan',price,round(price/1.22,2),price-round(price/1.22,2),'EUR',current_date-10,current_date+20,true);
  end loop;

  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[1];
  q:=public.rb_box_return_quote(orders[1],ids[1:10]);
  if(q->>'amount_cents')::int<>3800 or(q->>'package_after_cents')::int<>11400 or q?'unused_days' then raise exception 'TEST: 40 -> 30 ni razlika 152 - 114 = 38 EUR';end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  failed:=false;begin perform public.rb_prepare_box_refund(orders[1],ids[1:10],key1,3799,admin_id);exception when others then if sqlerrm like 'Znesek se je spremenil.%' then failed:=true;else raise;end if;end;
  if not failed or(select count(*) from public.skatle where narocnina_id=subs[1])<>40 then raise exception 'TEST: napačen znesek je premaknil boxe';end if;
  r:=public.rb_prepare_box_refund(orders[1],ids[1:10],key1,3800,admin_id);
  if(r->>'amount_cents')::int<>3800 or(r->'details'->>'kind')<>'initial_delivery' then raise exception 'TEST: evidenca nima pravega razloga';end if;
  if(select count(*) from public.skatle where narocnina_id=subs[1])<>30 or(select cena_mesecna from public.narocnine where id=subs[1])<>114
    or(select st_boxov from public.narocnine where id=subs[1])<>30 or(select st_boxov_dejansko from public.narocila where id=orders[1])<>30 then raise exception 'TEST: dejanska količina in paket nista usklajena';end if;
  if(select znesek from public.racuni where narocilo_id=orders[1] order by id desc limit 1)<>152 then raise exception 'TEST: originalni račun je bil prepisan';end if;
  r:=public.rb_prepare_box_refund(orders[1],ids[1:10],key1,3800,admin_id);
  if(select count(*) from public.rb_box_refunds where id=key1)<>1 then raise exception 'TEST: podvojitev vračila';end if;

  perform set_config('request.jwt.claims',claims,true);
  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[2];
  q:=public.rb_box_return_quote(orders[2],ids[1:4]);
  if(q->>'amount_cents')::int<>1120 or(q->>'package_after_cents')::int<>3920 then raise exception 'TEST: 12 -> 8 ne upošteva dražje enote novega paketa';end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  r:=public.rb_prepare_box_refund(orders[2],ids[1:4],key2,1120,admin_id);
  update public.rb_box_refunds set status='manual' where id=key2;
  q:=public.rb_box_return_quote(orders[2],ids[5:9]);
  if(q->>'amount_cents')::int<>2450 then raise exception 'TEST: ponovna korekcija ne izhaja iz preostalega paketa';end if;

  perform set_config('request.jwt.claims',claims,true);
  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[3];
  q:=public.rb_box_return_quote(orders[3],ids[1:10]);
  if(q->>'amount_cents')::int<>0 or q->>'mode'<>'zero' then raise exception 'TEST: enak izposojevalni paket mora imeti vračilo 0';end if;
  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[4];
  q:=public.rb_box_return_quote(orders[4],ids[1:20]);
  if(q->>'amount_cents')::int<>4000 or(q->>'package_after_cents')::int<>6900 then raise exception 'TEST: 40 -> 20 mora vrniti razliko 109 - 69';end if;
  failed:=false;begin perform public.rb_box_return_quote(orders[4],array[ids[1],ids[1]]);exception when others then failed:=true;end;
  if not failed then raise exception 'TEST: podvojeni boxi dovoljeni';end if;
  insert into public.zahteve_dostave(kupec_id,narocilo_id,status,brezplacna,datum_zahteve,datum_dostave,opomba)
    values(customer_id,orders[4],'nova',true,now(),current_date+10,'Prevoz v skladišče - QA') returning id into req;
  insert into public.zahteve_dostave_skatle(zahteva_id,skatla_id) values(req,ids[1]);
  failed:=false;begin perform public.rb_box_return_quote(orders[4],array[ids[1]]);exception when others then if sqlerrm like 'Za izbrane boxe je bil že naročen prevoz.%' then failed:=true;else raise;end if;end;
  if not failed then raise exception 'TEST: poznejši prevoz omogoča vračilo denarja';end if;

  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[5];
  perform public.sklad_vrni_boxe(orders[5],array[ids[1]]);
  failed:=false;begin perform public.rb_box_return_quote(orders[5],array[ids[2]]);exception when others then if sqlerrm like 'Po prvem prevzemu so bili boxi že vrnjeni.%' then failed:=true;else raise;end if;end;
  if not failed or(select cena_mesecna from public.narocnine where id=subs[5])<>14.70 then raise exception 'TEST: običajno vračilo spreminja plačano obdobje';end if;
  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[6];
  update public.narocnine set datum_od=datum_od+30,datum_do=datum_do+30 where id=subs[6];
  failed:=false;begin perform public.rb_box_return_quote(orders[6],array[ids[1]]);exception when others then if sqlerrm like 'Vračilo je mogoče samo za odvečne boxe ob prvi dostavi%' then failed:=true;else raise;end if;end;
  if not failed then raise exception 'TEST: obnovljeno naročilo dovoljuje vračilo prve dostave';end if;
  select array_agg(id order by id) into ids from public.skatle where narocnina_id=subs[7];
  failed:=false;begin perform public.rb_box_return_quote(orders[7],array[ids[1]]);exception when others then if sqlerrm like 'Paket za 25 boxov je dražji%' then failed:=true;else raise;end if;end;
  if not failed then raise exception 'TEST: dražji paket sproži izplačilo';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',gen_random_uuid(),'role','authenticated')::text,true);
  failed:=false;begin perform public.rb_box_return_quote(orders[7],array[ids[1]]);exception when others then if sqlerrm like 'Vračilo denarja lahko ureja samo administrator.%' then failed:=true;else raise;end if;end;
  if not failed then raise exception 'TEST: stranka dostopa do vračil';end if;
  if has_function_privilege('authenticated','public.rb_prepare_box_refund(bigint,bigint[],uuid,integer,uuid)','EXECUTE') then raise exception 'TEST: javna priprava vračila';end if;
end$test$;
select 'PASS: package difference, first delivery, zero refund, atomic update, retry, ordinary return and permissions' as result;
rollback;
