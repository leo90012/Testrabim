-- Izoliran preizkus v transakciji. ROLLBACK prepreči tudi oddajo HTTP obvestil.
do $test$
declare
  v_customer bigint; v_email text; v_staff uuid; v_order bigint; v_sub bigint;
  ids bigint[]; v_request bigint; v_other bigint; v_return bigint;
  v_day date := current_date+1000; v_rejected boolean; v_changed integer;
  v_queue bigint; v_own_claims text; v_staff_claims text;
begin
  select k.id,k.email into strict v_customer,v_email from public.kupci k
    join public.narocila o on o.kupec_id=k.id where o.stevilka='TEST-20261023-MATIC';
  select user_id into strict v_staff from public.osebje order by user_id limit 1;
  v_own_claims:=jsonb_build_object('sub',v_staff,'email',v_email,'role','authenticated')::text;
  v_staff_claims:=jsonb_build_object('sub',v_staff,'email','admin@rabimbox.si','role','authenticated')::text;
  perform set_config('request.jwt.claims',v_staff_claims,true);
  while extract(isodow from v_day)>5 loop v_day:=v_day+1;end loop;
  while exists(select 1 from public.zasedeni_termini(v_day)) loop
    v_day:=v_day+1;while extract(isodow from v_day)>5 loop v_day:=v_day+1;end loop;
  end loop;
  insert into public.narocila(is_test,vir,placano,tip,st_boxov,datum_dostave,status,email,ime,priimek,stevilka,naslov,mesto)
  values(true,'rocno',true,'skladiscenje',3,current_date,'pri_stranki',v_email,'QA','Prevoz','QA-TRANSPORT-'||gen_random_uuid(),'Testni naslov','Ljubljana') returning id into v_order;
  select id into strict v_sub from public.narocnine where narocilo_id=v_order;
  select array_agg(id) into ids from(select id from public.skatle where status='na_zalogi' and kupec_id is null order by id limit 3 for update)x;
  if cardinality(ids)<>3 then raise exception 'TEST: ni 3 prostih boxov';end if;
  select coalesce(max(id),0) into v_queue from net.http_request_queue;
  update public.skatle set narocnina_id=v_sub,kupec_id=v_customer,status='pri_stranki',tip_storitve='skladiscenje' where id=any(ids);
  if exists(select 1 from net.http_request_queue where id>v_queue and url like '%/poslji-obvestilo') then raise exception 'TEST: prva dostava še vedno sproži e-pošto';end if;

  perform set_config('request.jwt.claims',v_own_claims,true);
  select zahteva_id into strict v_request from public.rb_create_transport_requests(array[ids[1]],'prevoz_skladisce',v_day,'10:00','Testni naslov',null);
  if not exists(select 1 from public.rb_pending_transport_boxes() where skatla_id=ids[1]) then raise exception 'TEST: zahtevek ne zaklene boxa';end if;
  v_rejected:=false;
  begin perform public.rb_create_transport_requests(array[ids[1],ids[2]],'prevoz_skladisce',v_day,'11:00','Testni naslov',null);
  exception when others then if sqlerrm like 'Za enega ali več izbranih boxov je prevoz že naročen.%' then v_rejected:=true;else raise;end if;end;
  if not v_rejected then raise exception 'TEST: delno prekrivajoč zahtevek je bil sprejet';end if;
  select zahteva_id into strict v_other from public.rb_create_transport_requests(array[ids[2]],'prevoz_skladisce',v_day,'11:00','Testni naslov',null);

  perform set_config('request.jwt.claims',v_staff_claims,true);
  v_changed:=public.sklad_update_zahteva(v_request,'zahteva','caka_dostavo');
  if v_changed<>0 or (select status from public.skatle where id=ids[1])<>'pri_stranki' then raise exception 'TEST: interna potrditev premakne box';end if;
  if (select status from public.zahteve_dostave where id=v_request)<>'caka_dostavo' then raise exception 'TEST: skladišče ne vidi potrditve';end if;
  perform public.sklad_update_zahteva(v_order,'narocilo','caka_dostavo');
  if exists(select 1 from public.skatle where id=any(ids) and status<>'pri_stranki') then raise exception 'TEST: potrditev naročila premakne boxe';end if;
  perform set_config('request.jwt.claims',v_own_claims,true);
  v_rejected:=false;
  begin perform public.rb_create_transport_requests(array[ids[1]],'prevoz_skladisce',v_day,'12:00','Testni naslov',null);
  exception when others then if sqlerrm like 'Za enega ali več izbranih boxov je prevoz že naročen.%' then v_rejected:=true;else raise;end if;end;
  if not v_rejected then raise exception 'TEST: potrjen odprt zahtevek ni zaklenjen';end if;
  if exists(select 1 from public.rb_pending_transport_boxes() where skatla_id=ids[3]) then raise exception 'TEST: nepovezan box je zaklenjen';end if;
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"qa-no-customer@example.invalid"}',true);
  if exists(select 1 from public.rb_pending_transport_boxes()) then raise exception 'TEST: tuja stranka vidi zahtevke';end if;
  if has_function_privilege('anon','public.rb_pending_transport_boxes()','EXECUTE') then raise exception 'TEST: anon ima dostop';end if;

  perform set_config('request.jwt.claims',v_staff_claims,true);
  perform public.sklad_update_zahteva(v_request,'zahteva','preklicano');
  perform set_config('request.jwt.claims',v_own_claims,true);
  select zahteva_id into strict v_return from public.rb_create_transport_requests(array[ids[1],ids[3]],'prevoz_skladisce',v_day,'12:00','Testni naslov',null);
  perform set_config('request.jwt.claims',v_staff_claims,true);
  perform public.sklad_update_zahteva(v_return,'zahteva','v_skladiscu');
  if exists(select 1 from public.skatle where id=any(array[ids[1],ids[3]]) and (status<>'v_skladiscu' or kupec_id<>v_customer or narocnina_id<>v_sub)) then raise exception 'TEST: fizični prevzem ali lastništvo ni pravilno';end if;
  if not exists(select 1 from net.http_request_queue where id>v_queue and url like '%/poslji-obvestilo' and convert_from(body,'UTF8')::jsonb->>'tip'='prevzem') then raise exception 'TEST: mail ob prevzemu je izklopljen';end if;
  perform set_config('request.jwt.claims',v_own_claims,true);
  if exists(select 1 from public.rb_pending_transport_boxes() where skatla_id=ids[1]) then raise exception 'TEST: izveden prevoz ne sprosti izbire';end if;
  select zahteva_id into strict v_return from public.rb_create_transport_requests(array[ids[1]],'dostava',v_day,'13:00','Testni naslov',null);
  perform set_config('request.jwt.claims',v_staff_claims,true);
  perform public.sklad_update_zahteva(v_return,'zahteva','caka_dostavo');
  if (select status from public.skatle where id=ids[1])<>'v_skladiscu' then raise exception 'TEST: potrditev dostave premakne box iz skladišča';end if;
  perform public.sklad_update_zahteva(v_return,'zahteva','pri_stranki');
  if (select status from public.skatle where id=ids[1])<>'pri_stranki' then raise exception 'TEST: izvedena dostava ne spremeni boxa';end if;
  if not exists(select 1 from net.http_request_queue where id>v_queue and url like '%/poslji-obvestilo' and convert_from(body,'UTF8')::jsonb->>'faza'='vrnitev') then raise exception 'TEST: mail ob vrnitvi je izklopljen';end if;
end$test$;
select 'PASS: interna potrditev, podvojeni/prekrivajoči zahtevki, preklic, ločeni boxi, tuji dostop, fizični premiki, ročna prva dostava in ohranjena ostala obvestila' as rezultat;
