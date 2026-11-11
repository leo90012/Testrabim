begin;

create table if not exists public.rb_staff_notification_queue (
  kind text not null check (kind in ('narocilo','zahtevek')),
  source_id bigint not null,
  next_attempt_at timestamptz not null default now(),
  attempts integer not null default 0,
  processed_at timestamptz,
  primary key (kind, source_id)
);
create index if not exists rb_staff_notification_due
  on public.rb_staff_notification_queue(next_attempt_at) where processed_at is null;
alter table public.rb_staff_notification_queue enable row level security;
revoke all on public.rb_staff_notification_queue from public,anon,authenticated;
grant select, update on public.rb_staff_notification_queue to service_role;

create or replace function public.rb_queue_staff_notification()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_argv[0]='narocilo' then
    if new.is_test or new.status in ('zakljuceno','preklicano')
      or (new.placano is distinct from true and new.vir is distinct from 'rocno') then
      return new;
    end if;
    if tg_op='UPDATE' and (old.placano is true or old.vir='rocno') then
      return new;
    end if;
  elsif new.narocilo_id is not null and exists (
    select 1 from public.narocila where id=new.narocilo_id and is_test
  ) then
    return new;
  end if;

  insert into public.rb_staff_notification_queue(kind,source_id)
  values(tg_argv[0],new.id) on conflict do nothing;
  return new;
end $$;
revoke all on function public.rb_queue_staff_notification() from public,anon,authenticated;

create or replace trigger rb_staff_new_order
  after insert or update of placano,vir on public.narocila
  for each row execute function public.rb_queue_staff_notification('narocilo');
create or replace trigger rb_staff_new_request
  after insert on public.zahteve_dostave
  for each row execute function public.rb_queue_staff_notification('zahtevek');

create or replace function public.rb_send_staff_notifications()
returns void language plpgsql security definer set search_path=public as $$
declare v_key text;
begin
  if not exists (select 1 from public.rb_staff_notification_queue
    where processed_at is null and next_attempt_at<=now()) then return; end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name='rabimbox_service_role' limit 1;
  if v_key is null then raise exception 'Manjka ključ za pošiljanje obvestil.'; end if;
  perform net.http_post(
    url:='https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/poslji-obvestilo',
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key,'apikey',v_key),
    body:=jsonb_build_object('tip','lastnik_batch'),
    timeout_milliseconds:=25000
  );
end $$;
revoke all on function public.rb_send_staff_notifications() from public,anon,authenticated;

select cron.schedule('rabimbox-staff-notifications','* * * * *','select public.rb_send_staff_notifications()');
commit;
