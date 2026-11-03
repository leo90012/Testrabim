begin;
do $test$
declare
  customer_id bigint;customer_email text;admin_id uuid;own_claims text;staff_claims text;
  orders bigint[]:=array[]::bigint[];subs bigint[]:=array[]::bigint[];boxes bigint[];
  order_id bigint;sub_id bigint;req bigint;req2 bigint;day date:=current_date+1000;
  q jsonb;res jsonb;first_key uuid:=gen_random_uuid();second_key uuid:=gen_random_uuid();token uuid:=gen_random_uuid();rejected boolean;i integer;
begin
  select k.id,k.email into strict customer_id,customer_email from public.kupci k join public.narocila o on o.kupec_id=k.id where o.stevilka='TEST-20261023-MATIC';
  select user_id into strict admin_id from public.osebje where vloga='admin' order by user_id limit 1;
  own_claims:=jsonb_build_object('sub',gen_random_uuid(),'email',customer_email,'role','authenticated')::text;
  staff_claims:=jsonb_build_object('sub',admin_id,'email','admin@rabimbox.si','role','authenticated')::text;
  perform set_config('request.jwt.claims',staff_claims,true);
  while extract(isodow from day)>5 loop day:=day+1;end loop;
  while exists(select 1 from public.zasedeni_termini(day)) loop day:=day+1;while extract(isodow from day)>5 loop day:=day+1;end loop;end loop;
  for i in 1..3 loop
    insert into public.narocila(is_test,vir,placano,tip,st_boxov,datum_dostave,status,email,ime,priimek,stevilka,naslov,mesto)
    values(true,'rocno',true,case when i=2 then 'izposoja' else 'skladiscenje' end,case when i=2 then 1 else 3 end,current_date-10,'pri_stranki',customer_email,'QA','Vračilo','QA-RETURN-'||gen_random_uuid(),'Testni naslov','Ljubljana') returning id into order_id;
    select id into strict sub_id from public.narocnine n where n.narocilo_id=order_id;
    orders:=array_append(orders,order_id);subs:=array_append(subs,sub_id);
    update public.narocnine set datum_od=current_date-10,datum_do=current_date+20,st_boxov=case when i=2 then 1 else 3 end,cena_mesecna=90,status='aktivna' where id=sub_id;
    update public.racuni set obdobje_od=current_date-10,obdobje_do=current_date+20,placano=true,znesek=90,osnova=73.77,ddv=16.23 where narocilo_id=order_id;
    if not found then
      insert into public.racuni(narocilo_id,kupec_id,stevilka,placano,status,znesek,osnova,ddv,valuta,obdobje_od,obdobje_do,is_test)
      values(order_id,customer_id,'QA-INVOICE-'||gen_random_uuid(),true,'placan',90,73.77,16.23,'EUR',current_date-10,current_date+20,true);
    end if;
  end loop;
  select array_agg(id order by id) into boxes from(select s.id from public.skatle s where s.status='na_zalogi' and s.kupec_id is null
    and not exists(select 1 from public.zahteve_dostave_skatle zs join public.zahteve_dostave z on z.id=zs.zahteva_id where zs.skatla_id=s.id and z.status not in('zakljuceno','preklicano','v_skladiscu','pri_stranki')) order by s.id limit 7 for update)x;
  if cardinality(boxes)<>7 then raise exception 'TEST: ni 7 prostih boxov';end if;
  update public.skatle set kupec_id=customer_id,narocnina_id=subs[1],tip_storitve='skladiscenje',status='pri_stranki' where id=any(boxes[1:3]);
  update public.skatle set kupec_id=customer_id,narocnina_id=subs[2],tip_storitve='izposoja',status='pri_stranki' where id=boxes[4];
  update public.skatle set kupec_id=customer_id,narocnina_id=subs[3],tip_storitve='skladiscenje',status='pri_stranki' where id=any(boxes[5:7]);

  perform set_config('request.jwt.claims',own_claims,true);
  select zahteva_id into strict req from public.rb_create_transport_requests(array[boxes[1]],'vracilo_zakljucek',day,'10:00','Testni naslov',null);
  rejected:=false;begin perform public.sklad_vrni_zahtevek(req);exception when others then if sqlerrm='Nimate dovoljenja.' then rejected:=true;else raise;end if;end;
  if not rejected then raise exception 'TEST: stranka lahko vrača boxe v zalogo';end if;
  perform set_config('request.jwt.claims',staff_claims,true);
  q:=public.sklad_predogled_vracila_zahtevka(req);
  if (q->>'return_count')::int<>1 or(q->>'remaining_count')::int<>2 then raise exception 'TEST: predogled delnega vračila ni pravilen';end if;
  res:=public.sklad_vrni_zahtevek(req);
  if(res->>'returned_count')::int<>1 or(res->>'order_closed')::boolean or(select status from public.narocila where id=orders[1])='zakljuceno' then raise exception 'TEST: delno vračilo zaključi naročilo';end if;
  res:=public.sklad_vrni_zahtevek(req);
  if not(res->>'already_processed')::boolean or(res->>'returned_count')::int<>0 then raise exception 'TEST: ponovitev vračila ni varna';end if;
  perform set_config('request.jwt.claims',own_claims,true);
  select zahteva_id into strict req2 from public.rb_create_transport_requests(boxes[2:3],'vracilo_zakljucek',day,'11:00','Testni naslov',null);
  perform set_config('request.jwt.claims',staff_claims,true);
  res:=public.sklad_vrni_zahtevek(req2);
  if not(res->>'order_closed')::boolean or(res->>'remaining_count')::int<>0 or(select status from public.narocila where id=orders[1])<>'zakljuceno' then raise exception 'TEST: vračilo vseh ne zaključi naročila';end if;
  perform set_config('request.jwt.claims',own_claims,true);
  select zahteva_id into strict req2 from public.rb_create_transport_requests(array[boxes[4]],'vracilo_zakljucek',day,'12:00','Testni naslov',null);
  perform set_config('request.jwt.claims',staff_claims,true);
  res:=public.sklad_vrni_zahtevek(req2);
  if not(res->>'order_closed')::boolean then raise exception 'TEST: izposoja ni zaključena';end if;

  perform set_config('request.jwt.claims',own_claims,true);
  rejected:=false;begin perform public.rb_box_return_quote(orders[3],array[boxes[5]]);exception when others then if sqlerrm like 'Vračilo denarja lahko ureja samo administrator.%' then rejected:=true;else raise;end if;end;
  if not rejected then raise exception 'TEST: stranka vidi predogled vračila';end if;
  perform set_config('request.jwt.claims',staff_claims,true);
  q:=public.rb_box_return_quote(orders[3],array[boxes[5]]);
  if(q->>'amount_cents')::int<>2000 or(q->>'unused_days')::int<>20 or q->>'mode'<>'manual' then raise exception 'TEST: sorazmerni izračun ni 90/3*20/30=20 EUR';end if;
  rejected:=false;begin perform public.rb_box_return_quote(orders[3],array[boxes[5],boxes[5]]);exception when others then rejected:=true;end;
  if not rejected then raise exception 'TEST: podvojena izbira dovoljena';end if;
  if has_function_privilege('authenticated','public.rb_prepare_box_refund(bigint,bigint[],uuid,integer,uuid)','EXECUTE') or has_table_privilege('authenticated','public.rb_box_refunds','SELECT') then raise exception 'TEST: zasebna evidenca je izpostavljena';end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  rejected:=false;begin perform public.rb_prepare_box_refund(orders[3],array[boxes[5]],first_key,1999,admin_id);exception when others then if sqlerrm like 'Znesek se je spremenil.%' then rejected:=true;else raise;end if;end;
  if not rejected or(select status from public.skatle where id=boxes[5])<>'pri_stranki' then raise exception 'TEST: napačen potrjeni znesek je vrnil box';end if;
  q:=public.rb_prepare_box_refund(orders[3],array[boxes[5]],first_key,2000,admin_id);
  if(q->>'amount_cents')::int<>2000 or(select status from public.skatle where id=boxes[5])<>'na_zalogi' then raise exception 'TEST: priprava ne evidentira vračila in zaloge';end if;
  q:=public.rb_prepare_box_refund(orders[3],array[boxes[5]],first_key,2000,admin_id);
  if(select count(*) from public.rb_box_refunds where id=first_key)<>1 then raise exception 'TEST: ponovljeno vračilo se podvoji';end if;
  rejected:=false;begin perform public.rb_prepare_box_refund(orders[3],array[boxes[6]],first_key,2000,admin_id);exception when others then if sqlerrm like 'Ključ vračila je že uporabljen%' then rejected:=true;else raise;end if;end;
  if not rejected then raise exception 'TEST: isti ključ sprejme druge boxe';end if;
  q:=public.rb_claim_box_refund(first_key,token);
  rejected:=false;begin perform public.rb_claim_box_refund(first_key,gen_random_uuid());exception when others then if sqlerrm like 'Vračilo se že obdeluje.%' then rejected:=true;else raise;end if;end;
  if not rejected then raise exception 'TEST: manjka zaklep obdelave vračila';end if;
  update public.rb_box_refunds set status='manual',lease_token=null,lease_until=null where id=first_key;
  update public.skatle set kupec_id=customer_id,narocnina_id=subs[3],tip_storitve='skladiscenje',status='pri_stranki' where id=boxes[5];
  rejected:=false;begin perform public.rb_box_return_quote(orders[3],array[boxes[5]]);exception when others then if sqlerrm like 'Za enega od izbranih boxov je vračilo tega računa že evidentirano.%' then rejected:=true;else raise;end if;end;
  if not rejected then raise exception 'TEST: isti box in račun se lahko povrneta dvakrat';end if;
  update public.skatle set kupec_id=null,narocnina_id=null,tip_storitve=null,status='na_zalogi' where id=boxes[5];
  q:=public.rb_prepare_box_refund(orders[3],boxes[6:7],second_key,4000,admin_id);
  if(select sum(f.amount_cents) from public.rb_box_refunds f where f.order_id=orders[3])<>6000 then raise exception 'TEST: skupni sorazmerni znesek ni pravilen';end if;
  if(select cena_mesecna from public.narocnine where id=subs[3])<>90 or(select naslednje_st_boxov from public.narocnine where id=subs[3])<>0 then raise exception 'TEST: vračilo spremeni trenutno ceno namesto naslednjega obdobja';end if;
end$test$;

select 'PASS: request returns and refund ledger' as result;
rollback;
