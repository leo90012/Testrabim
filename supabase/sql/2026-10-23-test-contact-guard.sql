-- Testni primer ne prepisuje pravih kontaktnih podatkov obstoječe stranke.
create or replace function public.narocilo_posodobi_naslov() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.is_test then return new;end if;
  if new.kupec_id is not null then
    update public.kupci set
      postna_stevilka=coalesce(nullif(new.postna_stevilka,''),postna_stevilka),
      kraj=coalesce(nullif(new.mesto,''),kraj),
      naslov=coalesce(nullif(new.naslov,''),naslov),
      telefon=coalesce(nullif(new.telefon,''),telefon)
    where id=new.kupec_id;
  end if;
  return new;
end$$;
