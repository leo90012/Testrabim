# Pošiljanje računov po e-pošti (Resend + Supabase funkcija)

Ob oddaji naročila checkout že **ustvari in shrani račun** v tabelo `racuni`
(z osnovo, 22 % DDV in zneskom za plačilo) ter ga poskuša poslati po e-pošti.
E-pošta se pošlje prek Supabase Edge funkcije `poslji-racun`, ki uporablja
**Resend**. Da začne pošiljanje delovati, opravi spodnje korake.

## 1) Ustvari Resend račun in API ključ
1. Registriraj se na **resend.com** (brezplačni paket zadošča za začetek).
2. **API Keys → Create API Key** → kopiraj ključ (začne se z `re_...`).
3. (Priporočeno) **Domains → Add domain** → dodaj `rabimbox.si` in v DNS vpiši
   zapise, ki ti jih pokaže Resend. Ko je domena potrjena, lahko pošiljaš z
   naslova npr. `racuni@rabimbox.si`.
   - Za hiter test lahko pošiljaš z `onboarding@resend.dev` (brez domene), a
     e-pošta gre lahko v vsiljeno pošto.

## 2) Namesti funkcijo v Supabase
Najlažje prek **Supabase dashboarda**:
1. V Supabase odpri **Edge Functions → Deploy a new function** (ali `Create function`).
2. Ime: **`poslji-racun`**.
3. Prilepi vsebino datoteke `supabase/functions/poslji-racun/index.ts` (v tem projektu).
4. Klikni **Deploy**.

Ali prek ukazne vrstice (če imaš Supabase CLI):
```bash
supabase functions deploy poslji-racun --project-ref lvfnumhirarpshpqyoay
```

## 3) Dodaj skrivnosti (Secrets)
V Supabase: **Project Settings → Edge Functions → Secrets** (ali z ukazi):
```bash
supabase secrets set RESEND_API_KEY=re_xxxxxxxx
supabase secrets set RACUN_FROM="Rabimbox <racuni@rabimbox.si>"
```
- `RESEND_API_KEY` – ključ iz koraka 1.
- `RACUN_FROM` – naslov pošiljatelja (domena mora biti potrjena v Resend).
  Za test lahko uporabiš `Rabimbox <onboarding@resend.dev>`.

(`SUPABASE_URL` in `SUPABASE_SERVICE_ROLE_KEY` sta na voljo samodejno.)

## 4) Preizkus
Oddaj testno naročilo v checkoutu. Račun se shrani v tabelo `racuni`, funkcija
pa pošlje e-pošto stranki. Status računa se po uspešnem pošiljanju spremeni v
`poslan`.

---

### Opombe
- Če funkcija še ni nameščena, checkout vseeno **shrani račun** (viden v panelu
  Moj-profil → Računi za prijavljene stranke); prikaže se opomba, da bo e-pošta
  poslana po potrditvi. Pošiljanje začne delovati takoj, ko je funkcija
  nameščena in skrivnosti nastavljene.
- Zneski: cena paketa je obravnavana kot **končna cena z vključenim DDV**;
  na računu je razčlenjena na osnovo + 22 % DDV. Če želiš DDV prištevati zgoraj,
  spremeni izračun v `narocilo/js/checkout.js` (funkcija `submit`).
- Rok plačila je nastavljen na 8 dni po izdaji (spremenljivo v `checkout.js`).
