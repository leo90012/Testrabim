-- Oznake boxov RB0001 .. RB5000. Ohranimo ID-je in vse povezave.
-- Predvideno za obstoječih 360 zaporednih šestmestnih oznak.
begin;
lock table public.skatle in share row exclusive mode;

do $$
begin
  if (select count(*) from public.skatle) <> 360
     or (select count(*) from public.skatle
         where barkoda ~ '^RB[0-9]{6}$'
           and substring(barkoda from 3)::integer between 1 and 360) <> 360
     or (select count(distinct substring(barkoda from 3)::integer)
         from public.skatle) <> 360 then
    raise exception 'Oznake boxov so se spremenile; preveri jih pred preštevilčenjem.';
  end if;
  if (select last_value from public.skatle_barkoda_seq) <> 360 then
    raise exception 'Števec oznak ni več na 360; preveri nove boxe.';
  end if;
end $$;

create schema if not exists rabimbox_backup;
create table rabimbox_backup.barkode_pred_20260924 as
  select id,barkoda from public.skatle;
alter table rabimbox_backup.barkode_pred_20260924 enable row level security;
revoke all on schema rabimbox_backup from public;
revoke all on rabimbox_backup.barkode_pred_20260924 from public,anon,authenticated;

update public.skatle
set barkoda = 'RB' || lpad(substring(barkoda from 3)::integer::text, 4, '0');

alter sequence public.skatle_barkoda_seq maxvalue 5000 no cycle;
create or replace function public.set_barkoda()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.barkoda is null or new.barkoda = '' then
    new.barkoda := 'RB' || lpad(nextval('public.skatle_barkoda_seq')::text, 4, '0');
  end if;
  return new;
end;
$$;

do $$
begin
  if (select count(*) from public.skatle where barkoda ~ '^RB[0-9]{4}$') <> 360
     or (select count(distinct barkoda) from public.skatle) <> 360
     or (select min(barkoda) from public.skatle) <> 'RB0001'
     or (select max(barkoda) from public.skatle) <> 'RB0360' then
    raise exception 'Preverjanje novih oznak ni uspelo.';
  end if;
end $$;
commit;
