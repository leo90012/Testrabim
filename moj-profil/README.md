# Rabimbox – Uporabniški panel

Spletna aplikacija (deluje kot mobilna app) za stranke Rabimbox. Povezana je s tvojo
Supabase bazo. Stranka se prijavi in vidi svoje boxe, odda zahteve za dostavo/prevzem,
pregleda naročnino/račune ter ureja svoj profil.

Aplikacija je **statična** (HTML + CSS + JS, brez gradnje/build koraka) in uporablja
uradno Supabase JS knjižnico prek CDN.

---

## Vsebina map

```
rabimbox-panel/
├─ index.html          # vstopna točka
├─ manifest.json       # za "Dodaj na začetni zaslon" (PWA)
├─ css/styles.css      # slog
├─ js/config.js        # ⚙️ TUKAJ vpišeš anon ključ
├─ js/app.js           # celotna logika aplikacije
├─ sql/setup.sql       # varnostna pravila (RLS) — obvezno zaženi
└─ README.md
```

---

## Namestitev v 3 korakih

### 1) Vpiši anon (public) ključ
Odpri `js/config.js` in v `SUPABASE_ANON_KEY` prilepi svoj **anon public** ključ:

- Supabase → **Project Settings → API Keys → Legacy anon, service_role**
- kopiraj vrednost **anon public** (dolg niz, začne se z `eyJ…`)

> URL projekta je že vpisan. **Nikoli** ne vpisuj `service_role` ključa — ta obide vso varnost.

### 2) Zaženi varnostna pravila (RLS)
V Supabase odpri **SQL Editor**, prilepi vsebino datoteke `sql/setup.sql` in klikni **Run**.
To poskrbi, da vsaka stranka vidi **samo svoje** podatke.

> Pogoj: e-naslov v tabeli `kupci` mora biti enak e-naslovu, s katerim se stranka prijavi.

### 3) Odpri aplikacijo
Ker aplikacija kliče Supabase, jo je najbolje odpreti prek majhnega strežnika (ne z dvoklikom):

```bash
# v mapi rabimbox-panel:
python -m http.server 5173
# nato v brskalniku odpri:  http://localhost:5173
```

Za objavo na spletu preprosto naloži celotno mapo na kateri koli statični hosting
(Netlify, Vercel, Cloudflare Pages, GitHub Pages …) ali na poddomeno, npr.
`https://panel.rabimbox.si`.

---

## Avtentikacija (prijava strank)

Aplikacija uporablja **Supabase Auth** (e-pošta + geslo ali prijava prek e-povezave).
Ob prvi uporabi se stranka **registrira z istim e-naslovom**, kot ga ima v tabeli `kupci`.
Panel jo nato samodejno poveže s pravo vrstico stranke.

Priporočene nastavitve v Supabase → **Authentication**:
- **URL Configuration → Site URL**: naslov, kjer teče panel (npr. `https://panel.rabimbox.si`).
- Če želiš takojšnjo prijavo brez potrjevanja e-pošte: **Providers → Email → Confirm email = OFF**
  (za začetek testiranja; za produkcijo priporočamo potrditev vklopljeno).

Če stranka nima gesla, lahko klikne **E-povezava** in prejme povezavo za prijavo.

---

## Videz

Tema je usklajena z rabimbox.si (bela podlaga, modra `#0067ff`, zelena `#00a32a`,
pisavi DM Sans / Lexend), brez emojijev.

- **Na računalniku** izgleda kot spletna stran: leva stranska vrstica z navigacijo
  in vsebina na desni.
- **Na telefonu / tablici** deluje kot aplikacija: navigacija je v spodnji vrstici.

## Funkcije

| Zavihek | Kaj počne |
|---|---|
| **Nadzorna plošča** | Prikaz boxov ločeno *V skladišču* in *V najemu*; stranka označi boxe, ki jih želi dostaviti, in z gumbom odda naročilo. Zgoraj povzetek in status naročnine. |
| **Naročila** | Pregled in oddaja naročil za dostavo / prevzem / vrnitev (piše v `zahteve_dostave`) |
| **Računi** | Status naročnine; posamezni računi, če dodaš tabelo `racuni` |
| **Profil** | Urejanje imena, priimka, telefona in **naslova** (naslov, poštna številka, kraj); kontakt za podporo; odjava |

> Za naslov so bili v tabelo `kupci` dodani stolpci `naslov`, `postna_stevilka` in `kraj`
> (glej `sql/setup.sql`, razdelek 1b). Logo (`Slike/5.png`) in favicon (`Slike/3-scaled.png`)
> se nalagata iz mape `Slike/` — to mapo obdrži poleg aplikacije.

---

## Računi (neobvezno)

Trenutno tvoja baza nima tabele za posamezne račune. Če jo želiš, v `sql/setup.sql`
odkomentiraj razdelek **8) NEOBVEZNO: tabela za posamezne račune** in ga zaženi.
Panel bo račune samodejno prikazal v zavihku **Računi**.

---

## Prilagoditve

V `js/config.js` lahko nastaviš:
- `SUPPORT_EMAIL`, `SUPPORT_PHONE` – prikaz v zavihku Profil/Podpora,
- `BRAND_NAME` – ime blagovne znamke v glavi.

Barve so v `css/styles.css` (spremenljivke `:root { --brand … }`).

---

## Pogosta vprašanja

**Po prijavi piše "Račun ni povezan".**
E-naslov prijave se ne ujema z e-naslovom v tabeli `kupci`. Uskladi ju (ali dopolni e-naslov stranke v bazi).

**Seznam boxov je prazen, čeprav bi moral biti poln.**
Preveri, da so v tabeli `skatle` vrstice s pravim `kupec_id`, in da je bil `sql/setup.sql` uspešno zagnan.

**Napaka pri nalaganju / prazni podatki.**
Najpogosteje manjka RLS pravilo ali anon ključ. Preveri koraka 1 in 2 zgoraj.
