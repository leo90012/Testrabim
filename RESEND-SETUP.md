# E-pošta in računi (Resend + Supabase)

Spletno naročilo in plačan račun nastaneta šele po potrjenem plačilu Stripe.
Funkcija `poslji-obvestilo` pošlje stranki eno potrditev naročila z računom PDF
v priponki in obvesti skladišče. Neplačano spletno naročilo ne ustvari računa,
predračuna ali sporočila. Ročna naročila osebja so ločena in ne zahtevajo Stripe.

## Nastavitev

1. V Resend potrdi domeno `rabimbox.si` in omogoči pošiljanje z naslova
   `narocila@rabimbox.si`.
2. V Supabase Edge Functions Secrets nastavi `RESEND_API_KEY`.
3. Objavi funkcije `rapid-api` (izvorna mapa `stripe-checkout`),
   `Stripe-webhook`, `poslji-obvestilo`, `poslji-racun` in `sklad-rocni-vnos`.
4. V Stripe naj podpisani dogodki `checkout.session.completed` in
   `checkout.session.async_payment_succeeded` kličejo obstoječi endpoint
   `https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/Stripe-webhook`.
   Skrivnost podpisa nastavi v Supabase kot `STRIPE_WEBHOOK_SECRET`.

`SUPABASE_URL` in `SUPABASE_SERVICE_ROLE_KEY` sta v funkcijah na voljo samodejno.
Naslov pošiljatelja je določen v `poslji-obvestilo/index.ts`. Funkcija
`poslji-racun` izda PDF samo za plačan račun.

## Preverjanje

V testnem okolju dokončaj Stripe testno plačilo. Preveri, da se po potrditvi
ustvarita naročilo in plačan račun ter da stranka prejme eno potrditev s PDF.
Prekinjen checkout sme pustiti le zaseben osnutek v `checkout_osnutki`.

## Opomnik pred dostavo

Cron opravilo `rabimbox-dostava-opomnik` vsak dan ob 07:00 UTC pokliče
`rb_send_delivery_reminders()`. Funkcija `poslji-obvestilo` pošlje opomnik za
naslednji dan po datumu v Sloveniji. Velja za plačana spletna naročila,
ročna naročila in odprte zahtevke za prevoz. Sporočilo vsebuje vrsto prevoza,
datum, uro, naslov ter povezavo »Moj račun«.

Tabela `email_obvestila` preprečuje ponovno pošiljanje za isti termin.
Ob neuspelem pošiljanju se zapis sprosti, da je možen ponoven poskus.
Zaključni zahvalni e-mail uporablja povezavo za Google oceno v `REVIEW_URL`.
