-- Vse spremembe testov so v transakciji, ki se na koncu razveljavi.
begin;
set local request.jwt.claims='{"role":"service_role"}';
do $test$
declare n public.narocnine%rowtype; ids bigint[]; z bigint; inv bigint; again bigint; paid_start date; paid_end date; old_description text;
begin
  select * into strict n from public.narocnine where narocilo_id=(select id from public.narocila where stevilka='TEST-20261023-MATIC');
  if n.datum_do-n.datum_od<>30 then raise exception 'TEST: obdobje ni 30 dni';end if;
  select array_agg(id) into ids from(select id from public.skatle where status='na_zalogi' and kupec_id is null order by id limit 3 for update)x;
  if cardinality(ids)<>3 then raise exception 'TEST: premalo prostih testnih boxov';end if;
  update public.skatle set narocnina_id=n.id,kupec_id=n.kupec_id,status='pri_stranki' where id=any(ids);
  insert into public.zahteve_dostave(kupec_id,narocilo_id,status,brezplacna,datum_zahteve,datum_dostave,opomba)
  values(n.kupec_id,n.narocilo_id,'nova',true,(n.datum_do-4)::timestamptz,(n.datum_do-1)::timestamptz,'Vračilo - TEST') returning id into z;
  insert into public.zahteve_dostave_skatle(zahteva_id,skatla_id) values(z,ids[1]),(z,ids[2]);
  if public.rb_return_stops_renewal(n.narocilo_id) then raise exception 'TEST: delno vračilo ustavi celoten najem';end if;
  insert into public.zahteve_dostave_skatle(zahteva_id,skatla_id) values(z,ids[3]);
  if not public.rb_return_stops_renewal(n.narocilo_id) then raise exception 'TEST: pravočasno celotno vračilo ni prepoznano';end if;
  update public.zahteve_dostave set datum_zahteve=(n.datum_do-2)::timestamptz where id=z;
  if public.rb_return_stops_renewal(n.narocilo_id) then raise exception 'TEST: prepozno vračilo se šteje kot pravočasno';end if;
  update public.zahteve_dostave set datum_zahteve=(n.datum_do-4)::timestamptz,status='preklicano' where id=z;
  if public.rb_return_stops_renewal(n.narocilo_id) then raise exception 'TEST: preklicana zahteva ustavi obnovo';end if;
  paid_start:=n.datum_do;paid_end:=paid_start+30;
  update public.narocnine set naslednje_st_boxov=20,naslednja_cena=69,sprememba_od=paid_start where id=n.id;
  inv:=public.rb_record_stripe_invoice(jsonb_build_object('subscription_id',n.stripe_subscription_id,'invoice_id','TEST-DB-INVOICE-1','number','TEST-DB-INVOICE-1','amount_cents',6900,'box_count',20,'period_start',paid_start,'period_end',paid_end,'period_end_ts',paid_end::timestamptz,'description','TESTNO OBDOBJE'));
  again:=public.rb_record_stripe_invoice(jsonb_build_object('subscription_id',n.stripe_subscription_id,'invoice_id','TEST-DB-INVOICE-1'));
  if inv<>again or(select count(*) from public.racuni where stripe_invoice_id='TEST-DB-INVOICE-1')<>1 then raise exception 'TEST: podvojen račun';end if;
  if not exists(select 1 from public.narocnine where id=n.id and st_boxov=20 and cena_mesecna=69 and datum_do=paid_end and naslednje_st_boxov is null) then raise exception 'TEST: nova količina ali obdobje ni pravilno';end if;
  update public.racuni set obdobje_od=paid_start+1,opis='NE SME SE SPREMENITI' where id=inv;
  if not exists(select 1 from public.racuni where id=inv and obdobje_od=paid_start and opis='TESTNO OBDOBJE') then raise exception 'TEST: zgodovinski račun se spreminja';end if;
  perform public.rb_record_stripe_invoice(jsonb_build_object('subscription_id',n.stripe_subscription_id,'invoice_id','TEST-DB-INVOICE-OLD','number','TEST-DB-INVOICE-OLD','amount_cents',10900,'box_count',40,'period_start',n.datum_od,'period_end',n.datum_do,'period_end_ts',n.datum_do::timestamptz,'description','TEST STAR DOGODEK'));
  if not exists(select 1 from public.narocnine where id=n.id and datum_do=paid_end and st_boxov=20) then raise exception 'TEST: star dogodek zavrti obdobje nazaj';end if;
  update public.zahteve_dostave set status='nova' where id=z;
  update public.narocila set status='zakljuceno' where id=n.narocilo_id;
  if not exists(select 1 from public.zahteve_dostave where id=z and status='zakljuceno') then raise exception 'TEST: zaključek ne zapre prevoza';end if;
  if has_table_privilege('authenticated','public.rb_email_log','SELECT') or has_table_privilege('anon','public.rb_email_log','SELECT') then raise exception 'TEST: dnevnik je neposredno dostopen';end if;
  if has_function_privilege('anon','public.rb_record_stripe_invoice(jsonb)','EXECUTE') or has_function_privilege('authenticated','public.rb_record_stripe_invoice(jsonb)','EXECUTE') then raise exception 'TEST: finančni RPC je dostopen stranki';end if;
end$test$;
select 'PASS: 30 dni, delno/celotno/prepozno/preklicano vračilo, brez podvojenih računov, zgodovinski račun, vrstni red dogodkov, zapiranje prevoza, dovoljenja' as rezultat;
rollback;
