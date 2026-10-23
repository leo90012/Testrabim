-- Naročilo kaže samo svoje boxe; brez starega rezervnega izbora vseh boxov kupca.
create or replace function public.sklad_zahteva_skatle(p_id bigint, p_vir text default 'zahteva')
returns table(id bigint, barkoda text, status text, lokacija text, vezana boolean)
language sql stable security definer set search_path=public as $$
  select s.id,s.barkoda,s.status,s.lokacija,true
  from public.skatle s
  where public.is_staff() and (
    (p_vir='narocilo' and exists(select 1 from public.narocnine n where n.id=s.narocnina_id and n.narocilo_id=p_id))
    or (p_vir='zahteva' and exists(select 1 from public.zahteve_dostave_skatle zs where zs.skatla_id=s.id and zs.zahteva_id=p_id))
  ) order by s.id;
$$;
