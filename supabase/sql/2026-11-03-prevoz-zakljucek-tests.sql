begin;
-- Izvede se skupaj s kandidatno funkcijo v BEGIN/ROLLBACK; brez trajnih naročil ali pošte.
do $test$
declare
  v_customer bigint; v_email text; v_staff uuid; v_skl bigint; v_naj bigint;
  v_skl_sub bigint; v_naj_sub bigint; ids bigint[]; r_close bigint; r_normal bigint;
  v_day date:=current_date+1000; v_rejected boolean; v_count integer;
  v_owner text; v_employee text;
begin
  select k.id,k.email into strict v_customer,v_email from public.kupci k
    join public.narocila o on o.kupec_id=k.id where o.stevilka='TEST-20261023-MATIC';
  select user_id into strict v_staff from public.osebje order by user_id limit 1;
  v_owner:=jsonb_build_object('sub',v_staff,'email',v_email,'role','authenticated')::text;
  v_employee:=jsonb_build_object('sub',v_staff,'email','admin@rabimbox.si','role','authenticated')::text;
  perform set_config('request.jwt.claims',v_employee,true);
  while extract(isodow from v_day)>5 loop v_day:=v_day+1;end loop;
  while exists(select 1 from public.zasedeni_termini(v_day)) loop
    v_day:=v_day+1;while extract(isodow from v_day)>5 loop v_day:=v_day+1;end loop;
  end loop;
  insert into public.narocila(is_test,vir,placano,tip,st_boxov,datum_dostave,status,email,ime,priimek,stevilka,naslov,mesto)
  values(true,'rocno',true,'skladiscenje',2,current_date,'pri_stranki',v_email,'QA','Zaključek','QA-CLOSE-SKL-'||gen_random_uuid(),'Testni naslov','Ljubljana') returning id into v_skl;
  insert into public.narocila(is_test,vir,placano,tip,st_boxov,datum_dostave,status,email,ime,priimek,stevilka,naslov,mesto)
  values(true,'rocno',true,'izposoja',2,current_date,'pri_stranki',v_email,'QA','Zaključek','QA-CLOSE-NAJ-'||gen_random_uuid(),'Testni naslov','Ljubljana') returning id into v_naj;
  select id into strict v_skl_sub from public.narocnine where narocilo_id=v_skl;
  select id into strict v_naj_sub from public.narocnine where narocilo_id=v_naj;
  select array_agg(id order by id) into ids from(select id from public.skatle where status='na_zalogi' and kupec_id is null order by id limit 4 for update)x;
  if cardinality(ids)<>4 then raise exception 'TEST: ni 4 prostih boxov';end if;
  update public.skatle set narocnina_id=v_skl_sub,kupec_id=v_customer,status='pri_stranki',tip_storitve='skladiscenje' where id=any(ids[1:2]);
  update public.skatle set narocnina_id=v_naj_sub,kupec_id=v_customer,status='pri_stranki',tip_storitve='izposoja' where id=any(ids[3:4]);

  perform set_config('request.jwt.claims',v_owner,true);
  select zahteva_id into strict r_close from public.rb_create_transport_requests(array[ids[1]],'vracilo_zakljucek',v_day,'10:00','Testni naslov',null);
  if (select count(*) from public.zahteve_dostave_skatle where zahteva_id=r_close)<>1
    or not exists(select 1 from public.zahteve_dostave where id=r_close and narocilo_id=v_skl and opomba like 'Vračilo in zaključek naročila - Naslov:%') then
    raise exception 'TEST: delni zahtevek ali povezava/oznaka ni pravilna';
  end if;
  if (select status from public.narocila where id=v_skl)<>'pri_stranki'
    or exists(select 1 from public.skatle where id=any(ids) and status<>'pri_stranki') then
    raise exception 'TEST: oddaja je premaknila boxe ali zaključila naročilo';
  end if;
  v_rejected:=false;
  begin perform public.rb_create_transport_requests(array[ids[1],ids[2]],'prevoz_skladisce',v_day,'11:00','Testni naslov',null);
  exception when others then if sqlerrm like 'Za enega ali več izbranih boxov je prevoz že naročen.%' then v_rejected:=true;else raise;end if;end;
  if not v_rejected then raise exception 'TEST: podvojen zahtevek dovoljen';end if;

  select zahteva_id into strict r_normal from public.rb_create_transport_requests(array[ids[3]],'vracilo_zakljucek',v_day,'11:00','Testni naslov',null);
  select count(*) into v_count from public.rb_create_transport_requests(array[ids[2],ids[4]],'vracilo_zakljucek',v_day,'12:00','Testni naslov',null);
  if v_count<>2 then raise exception 'TEST: več naročil ni razdeljenih na dva zahtevka';end if;

  perform set_config('request.jwt.claims',v_employee,true);
  if not exists(select 1 from public.sklad_zahteve() where id=r_close and vir='zahteva' and vrsta='Vračilo in zaključek naročila') then
    raise exception 'TEST: skladišče ne vidi nove vrste';
  end if;
  perform public.sklad_update_zahteva(r_close,'zahteva','caka_dostavo');
  if (select status from public.skatle where id=ids[1])<>'pri_stranki'
    or (select status from public.narocila where id=v_skl)<>'pri_stranki' then
    raise exception 'TEST: interna potrditev ima fizični učinek';
  end if;
  perform public.sklad_update_zahteva(r_close,'zahteva','v_skladiscu');
  if not exists(select 1 from public.skatle where id=ids[1] and status='na_zalogi' and kupec_id is null)
    or (select status from public.narocila where id=v_skl)<>'pri_stranki' then
    raise exception 'TEST: prevzem novega zahtevka ni pravilen ali samodejno zaključi naročilo';
  end if;

  -- Preostale zahteve prekličemo samo znotraj testne transakcije.
  update public.zahteve_dostave set status='preklicano' where narocilo_id in(v_skl,v_naj) and id<>r_close;
  update public.skatle set status='v_skladiscu' where id=ids[2];
  perform set_config('request.jwt.claims',v_owner,true);
  v_rejected:=false;
  begin perform public.rb_create_transport_requests(array[ids[2]],'vracilo_zakljucek',v_day,'13:00','Testni naslov',null);
  exception when others then if sqlerrm like 'Nekateri boxi niso več na voljo%' then v_rejected:=true;else raise;end if;end;
  if not v_rejected then raise exception 'TEST: zaključek dovoljen za box v skladišču';end if;
  v_rejected:=false;
  begin perform public.rb_create_transport_requests(array[ids[3]],'vracilo_zakljucek',current_date,'13:00','Testni naslov',null);
  exception when others then v_rejected:=true;end;
  if not v_rejected then raise exception 'TEST: manjka 3-dnevni zamik';end if;
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"qa-nobody@example.invalid"}',true);
  v_rejected:=false;
  begin perform public.rb_create_transport_requests(array[ids[3]],'vracilo_zakljucek',v_day,'13:00','Testni naslov',null);
  exception when others then if sqlerrm='Prijava je potrebna.' then v_rejected:=true;else raise;end if;end;
  if not v_rejected then raise exception 'TEST: tuja stranka ima dostop';end if;

  perform set_config('request.jwt.claims',v_employee,true);
  update public.skatle set status='pri_stranki' where id=ids[2];
  perform set_config('request.jwt.claims',v_owner,true);
  select zahteva_id into strict r_normal from public.rb_create_transport_requests(array[ids[2]],'prevoz_skladisce',v_day,'13:00','Testni naslov',null);
  if not exists(select 1 from public.zahteve_dostave where id=r_normal and opomba like 'Prevoz v skladišče - %') then raise exception 'TEST: običajen prevoz spremenjen';end if;
  perform set_config('request.jwt.claims',v_employee,true);
  perform public.sklad_update_zahteva(r_normal,'zahteva','v_skladiscu');
  if not exists(select 1 from public.skatle where id=ids[2] and status='v_skladiscu' and kupec_id=v_customer and narocnina_id=v_skl_sub) then
    raise exception 'TEST: običajen prevoz sprosti box skladiščenja';
  end if;
  perform public.sklad_zakljuci_narocilo(v_skl,null);
  if (select status from public.narocila where id=v_skl)<>'zakljuceno'
    or (select status from public.zahteve_dostave where id=r_close)<>'zakljuceno' then
    raise exception 'TEST: ročni zaključek ne zapre povezanega zahtevka';
  end if;
end$test$;

select 'PASS: prevoz in ročni zaključek naročila' as rezultat;
rollback;
