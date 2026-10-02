-- Opomnik dan pred dostavo. Aktivni secret API key naj bo v Vault shranjen
-- kot rabimbox_service_role. Ključa ne vpisujemo v SQL ali izvorno kodo.
create or replace function public.rb_send_delivery_reminders()
returns void language plpgsql security definer set search_path = public as $$
declare v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets
    where name = 'rabimbox_service_role' limit 1;
  if v_key is null then raise exception 'Manjka rabimbox_service_role v Vault.'; end if;
  perform net.http_post(
    url := 'https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/poslji-obvestilo',
    headers := jsonb_build_object('Content-Type','application/json','apikey',v_key),
    body := jsonb_build_object('tip','dostava_opomnik_batch')
  );
end; $$;
revoke all on function public.rb_send_delivery_reminders() from public, anon, authenticated;
select cron.schedule('rabimbox-dostava-opomnik', '0 7 * * *', 'select public.rb_send_delivery_reminders()');
