# Stripe plačilo (Checkout) – navodila za namestitev

Checkout zdaj ob oddaji naročila stranko preusmeri na **Stripe Checkout**
(varna Stripe plačilna stran, enkratno plačilo prvega meseca). Po plačilu
Stripe pokliče naš **webhook**, ki naročilo označi kot plačano, izda račun in
ga pošlje po e-pošti.

Deluje šele, ko opraviš spodnje korake. Do takrat checkout deluje po starem
(naročilo brez spletnega plačila) — varovalo, da stran ne odpove.

## Datoteke (že v projektu)
- `supabase/functions/stripe-checkout/index.ts` – ustvari plačilno sejo.
- `supabase/functions/stripe-webhook/index.ts` – obdela uspešno plačilo.
- (obstoječa) `supabase/functions/poslji-racun/index.ts` – pošlje PDF račun.
- `narocilo/js/checkout.js` – preusmeri na Stripe in obravnava vrnitev.

---

## 1) Stripe ključi
V Stripe Dashboard (za začetek **Test mode**, stikalo zgoraj desno):
- **Developers → API keys** → kopiraj **Secret key** (`sk_test_...`). 
  (Publishable ključa pri Checkout preusmeritvi ne rabiš.)

## 2) Objavi obe edge funkciji v Supabase
Najlažje prek **Supabase Dashboard → Edge Functions → Deploy a new function**
(ali `Create function`). Za vsako:
- **`stripe-checkout`** – prilepi vsebino `stripe-checkout/index.ts`, Deploy.
- **`stripe-webhook`** – prilepi vsebino `stripe-webhook/index.ts`, Deploy, nato
  pri tej funkciji **izklopi "Verify JWT"** (Stripe ne pošilja Supabase žetona).
- (če še ni) **`poslji-racun`** – prilepi `poslji-racun/index.ts`, Deploy.

Prek CLI (če ga imaš):
```bash
supabase functions deploy stripe-checkout --project-ref lvfnumhirarpshpqyoay
supabase functions deploy stripe-webhook  --project-ref lvfnumhirarpshpqyoay --no-verify-jwt
supabase functions deploy poslji-racun    --project-ref lvfnumhirarpshpqyoay
```

## 3) Dodaj skrivnosti (Secrets)
Supabase → **Project Settings → Edge Functions → Secrets** (ali z ukazi):
```bash
supabase secrets set STRIPE_SECRET_KEY=sk_test_xxxxx
# STRIPE_WEBHOOK_SECRET dodaš v koraku 4
# (RESEND_API_KEY / RACUN_FROM za pošiljanje računa – glej RESEND-SETUP.md)
```

## 4) Nastavi Stripe webhook
Stripe Dashboard → **Developers → Webhooks → Add endpoint**:
- **Endpoint URL:**
  `https://lvfnumhirarpshpqyoay.supabase.co/functions/v1/stripe-webhook`
- **Events to send:** izberi **`checkout.session.completed`**.
- Shrani, nato odpri endpoint in kopiraj **Signing secret** (`whsec_...`).
- V Supabase dodaj skrivnost:
```bash
supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxxxx
```

## 5) Baza (za vsak slučaj – idempotentno)
V Supabase SQL Editor:
```sql
alter table public.narocila add column if not exists placano boolean default false;
alter table public.narocila add column if not exists stevilka text;
```

## 6) Preizkus (Test mode)
1. Oddaj testno naročilo v checkoutu → preusmeri te na Stripe.
2. Plačaj s testno kartico **4242 4242 4242 4242**, poljuben datum/CVC.
3. Po plačilu te vrne na stran s potrditvijo "Plačilo uspešno".
4. Preveri: `narocila.placano = true`, nov zapis v `racuni`, e-mail z računom.
   Webhook status vidiš v Stripe Dashboard → Webhooks (naj bo 200).

## 7) Produkcija
Ko vse dela v Test mode: v Stripe preklopi na **Live**, ponovi koraka 1 in 4 z
**live** ključi (`sk_live_...`, nov `whsec_...`) in posodobi obe skrivnosti.

---

### Opombe
- Znesek se **vedno izračuna na strežniku** iz naročila (klientu ne zaupamo).
- Cenik v `stripe-checkout` in `stripe-webhook` (funkcija `znesekZa`) se mora
  ujemati s cenami v `narocilo/js/checkout.js` (IZP 49/89/119/149; SKL po boxu
  3,90 / 3,60 / 3,30). Če spremeniš cene, popravi na obeh mestih.
- Trenutno je to **enkratno** plačilo prvega meseca. Ponavljajočo naročnino
  (Stripe Subscriptions) dodava kasneje, če želiš.
