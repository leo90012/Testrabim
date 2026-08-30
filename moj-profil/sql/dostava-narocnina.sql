-- ============================================================
--  Rabimbox – Naročnina: začetek = dan dostave, obnova = mesec − 1 dan
--  Zaženi v Supabase SQL Editor (Dashboard -> SQL Editor -> Run).
--  Ko admin v skladiščni aplikaciji označi škatlo kot "pri_stranki"
--  (dostavljeno), se naročnini nastavi:
--    datum_od = današnji dan (če še ni),
--    datum_do = datum_od + 1 mesec − 1 dan,
--    status   = aktivna.
-- ============================================================
create or replace function public.sklad_update_box(
  p_id bigint, p_barkoda text default null, p_status text default null,
  p_kupec_email text default null, p_lokacija_koda text default null, p_opomba text default null,
  p_datum_od date default null, p_datum_do date default null, p_nar_status text default null
) returns void language plpgsql security definer set search_path=public as $$
declare v_lok bigint; v_kup bigint;
begin
  if not public.is_admin() then raise exception 'Samo administrator lahko ureja.'; end if;

  if p_lokacija_koda is not null and length(trim(p_lokacija_koda))>0 then
    select id into v_lok from public.skladisce_lokacije where koda = trim(p_lokacija_koda) limit 1;
    if v_lok is null then insert into public.skladisce_lokacije(koda) values(trim(p_lokacija_koda)) returning id into v_lok; end if;
  else v_lok := null; end if;

  if p_kupec_email is not null and length(trim(p_kupec_email))>0 then
    select id into v_kup from public.kupci where lower(email)=lower(trim(p_kupec_email)) limit 1;
    if v_kup is null then raise exception 'Stranka z e-naslovom % ne obstaja.', p_kupec_email; end if;
  else v_kup := null; end if;

  update public.skatle set
    barkoda = coalesce(nullif(trim(p_barkoda),''), barkoda),
    status  = coalesce(nullif(trim(p_status),''), status),
    kupec_id = v_kup, lokacija_id = v_lok, opomba = p_opomba, updated_at = now()
  where id = p_id;

  if lower(coalesce(p_status,'')) = 'pri_stranki' then
    -- dostavljeno: zacetek = danes, obnova = mesec - 1 dan
    update public.narocnine n set
      datum_od = coalesce(n.datum_od, current_date),
      datum_do = (coalesce(n.datum_od, current_date) + interval '1 month' - interval '1 day')::date,
      status = 'aktivna', updated_at = now()
    from public.skatle s where s.id = p_id and n.id = s.narocnina_id;
  else
    update public.narocnine n set
      datum_od = coalesce(p_datum_od, n.datum_od),
      datum_do = coalesce(p_datum_do, n.datum_do),
      status = coalesce(nullif(trim(p_nar_status),''), n.status),
      updated_at = now()
    from public.skatle s where s.id = p_id and n.id = s.narocnina_id;
  end if;

  insert into public.skladisce_dogodki(skatla_id, lokacija_id, dejanje, status_nov, uporabnik, opomba)
  values (p_id, v_lok, 'urejanje', p_status, coalesce(auth.jwt()->>'email','admin'), 'Rocna sprememba prek skladiscne aplikacije');
end;$$;
grant execute on function public.sklad_update_box(bigint,text,text,text,text,text,date,date,text) to authenticated;
