# NAVODILA ZA DELAVCE – Rabimbox (lokalna verzija)

Vodja projekta. Datum: 24. 7. 2026. Vse spremembe delamo LOKALNO v mapi `rabimbox-site`. Žive strani ne posodabljamo.

## Preverjeno / predpostavke (potrjeno s šefom, razen kjer piše ODLOČITEV)

- "Kontakt" link v lokalnih straneh NE obstaja (preverjeno na vseh 5 straneh) — obstaja samo gumb "Kontaktiraj nas" na strani O nas, ki OSTANE. Delavec A samo še enkrat preveri header + mobilni meni.
- Veljavnost naročnine je v bazi vezana na kupca (`kupci.datum_konca_narocnine`), ne na posamezen box. ODLOČITEV: ob vsakem boxu prikažemo kupčev datum konca naročnine. Če se kasneje doda stolpec per-box, zamenjamo vir.
- ODLOČITEV termini: dostave 10:00–15:00, vsaka traja 1 uro → začetni termini 10:00, 11:00, 12:00, 13:00, 14:00 (zadnja dostava se konča ob 15:00).
- ODLOČITEV "okolica Ljubljane": poštne številke 1000, 1210, 1211, 1215, 1231, 1235, 1236, 1260, 1261, 1262, 1290–1296, 1351–1360, 1370, ALI kraj vsebuje "ljubljana" (neodvisno od velikih črk). Seznam je konstanta `LJ_POSTE` — šef ga lahko kadarkoli prilagodi.
- Slika ozadja je `Slike/Ozadje.png` (velika začetnica!).
- Stripe še ni integriran — gumbi za plačilo ostanejo obstoječi stub (toast). Ne gradite plačilnega flowa.

---

## DELAVEC A — Statične strani (footer)

Datoteke: `index.html`, `izposoja/index.html`, `skladiscenje/index.html`, `cenik/index.html`, `o-nas/index.html`

1. V footer navigaciji vsake strani premakni linka **"Moj profil"** in **"Naroči zdaj"** čisto na desno stran:
   - Footer meni je `<ul>` z `<li class="menu-item ...">`; linka imata classa `menu-item-mojprofil` in `menu-item-narocizdaj`.
   - Poskrbi, da sta ta dva `<li>` ZADNJA v seznamu (za "Pravila in pogoji"), nato v CSS dodaj: `.menu-item-mojprofil { margin-left: auto; }` (footer nav mora biti `display:flex`; če ni, dodaj flex na footer `<ul>` samo v footerju, ne v headerju).
   - POZOR: ista classa se uporabljata tudi v header meniju — CSS pravilo omeji na footer selektor (npr. `footer .menu-item-mojprofil` oz. ustrezen Elementor wrapper), da ne razbiješ headerja.
2. Preveri, da nikjer (header, mobilni meni, footer) ni linka "Kontakt" — razen "Kontaktiraj nas" na O nas, ki ostane nedotaknjen.
3. Test: odpri vseh 5 strani lokalno, preveri desktop + mobilno širino (DevTools), da se footer ne zlomi.

**Sprejemni kriterij:** na vseh 5 straneh sta "Moj profil" in "Naroči zdaj" v footerju poravnana desno; header nespremenjen.

---

## DELAVEC B — Nadzorna plošča (Moj profil)

Datoteka: `Moj-profil/js/app.js` (+ po potrebi `css/styles.css`)

1. **Gumb "Izberi vsa neplačana"** — sekcija `neplacanoSection` (fn `viewNadzor`, ~vrstica 217):
   - Vsaki vrstici neplačanega naročila dodaj checkbox (class `unpaid-check`, value = id naročila).
   - Nad seznam dodaj gumb **"Izberi vsa neplačana"** (toggle: če so vsa izbrana, odznači). Ob izbiri se posodobi skupni znesek in gumb "Plačilo izbranih (n)" — klik zaenkrat pokaže obstoječi toast "Plačilo (Stripe) bo kmalu na voljo."
2. **Gumb "Izberi vse v skladišču"** — nad skupino "V skladišču" dodaj gumb, ki označi vse `.box-check` znotraj te skupine (in sproži obstoječi `update()`, da se aktivira "Naroči dostavo izbranih"). Skupini v `group()` dodaj `data-group="skl"` za selektor.
3. **Skrij barkodo** — v `rowH` (~vrstica 223) in v `newOrder` sheetu (~vrstica 283) zamenjaj `b.barkoda || "Box #" + b.id` z **`"Box #" + b.id`**. Barkoda se kupcu nikjer ne sme prikazati.
4. **Veljavnost naročnine ob boxu** — v `rowH` v podvrstico (`.s`) dodaj: `Naročnina do: ${fmtDate(state.kupec.datum_konca_narocnine)}` (lokacijo lahko pustiš pred tem, ločeno z " · ").
5. **Dva gumba kot na strani naročila** — na vrh nadzorne plošče (pod `stats`) dodaj dva "choice" gumba/kartici v stilu checkouta (`narocilo` stran, korak izbire):
   - **"Izposoja"** → `../narocilo/index.html?tip=izposoja`
   - **"Skladiščenje"** → `../narocilo/index.html?tip=skladiscenje`
   - Stil kopiraj/približaj `.choice-grid`/`.choice` iz `narocilo/css/checkout.css`.
   - (Delavec C bo poskrbel, da checkout prebere `?tip=` parameter.)

**Sprejemni kriterij:** brez barkod; vsak box prikazan kot "Box #ID" + datum naročnine; oba "izberi vse" gumba delujeta; kartici Izposoja/Skladiščenje vodita na checkout s pravim tipom.

---

## DELAVEC C — Stran "Naroči zdaj" (checkout)

Datoteki: `narocilo/js/checkout.js`, `narocilo/css/checkout.css`

0. **Priprava:** skopiraj `Slike/Ozadje.png` (koren projekta) v `narocilo/Slike/Ozadje.png`. Dodaj branje URL parametra: če je `?tip=izposoja` ali `?tip=skladiscenje`, nastavi `s.tip` in začni na koraku `paketi` (preskoči choice).

1. **Ozadje na koraku izbire** (`viewChoice`): samo na tem koraku nastavi ozadje `Slike/Ozadje.png` (npr. class `bg-choice` na body/wrapper: `background: url("Slike/Ozadje.png") center/cover no-repeat;`). Pri prehodu na naslednji korak class odstrani. Poskrbi za čitljivost kartic (bel overlay/box-shadow po potrebi).

2. **Korak 1 – Paketi** (`infoBlock`, ~vrstica 263): zamenjaj blok "Koliko prostora potrebujem?" z:
   - Naslov: **"Kakšne predmete lahko hranim?"**
   - Odstavek: "Shranite lahko večino gospodinjskih in pisarniških predmetov. **Ne shranjujemo krhkih predmetov** (steklo, porcelan, občutljiva elektronika brez zaščite) **in predmetov, ki so z zakonom prepovedani** (nevarne, vnetljive ali ilegalne snovi). Pri skladiščenju je minimalno obdobje 3 mesece."

3. **Korak 2 – Dodatki** (`viewDodatki`): odstrani vrstico `xrow("fragile","krhko",...)`. Odstrani "krhko" tudi iz `extrasLabel()` in iz povzetka (`viewPovzetek` – vrstica `kv("Krhki predmeti",...)`). V zapisu za bazo (`rec`) pošlji `krhko: false` (stolpec v bazi ostane).

4. **Korak 3 – Termin** (`viewTermin`):
   - Dodaj polja: **Ime, Priimek, Naslov** (obstoječe polje ostane), **Poštna številka** (`postna`), **Mesto** (`mesto`), **Telefon** (obstoječe), **E-pošta**. Vse shranjuj v state `s` (dodaj `s.postna`, `s.mesto`; `s.ime/s.priimek/s.email` že obstajajo — na koraku Račun jih PREDIZPOLNI, ne podvajaj vnosa).
   - **Ljubljana check:** konstanta `LJ_POSTE = ["1000","1210","1211","1215","1231","1235","1236","1260","1261","1262","1290","1291","1292","1293","1294","1295","1296","1351","1354","1355","1356","1357","1358","1360","1370"]`. Dovoljena dostava, če je `s.postna` v seznamu ALI `s.mesto.toLowerCase().includes("ljubljana")`.
   - Če NI dovoljeno: gumb "Naprej" se zamenja z gumbom **"Kontaktiraj nas"** (`mailto:info@rabimbox.si?subject=Povpraševanje – dostava izven Ljubljane`), pod gumbom pa napis: *"Online naročilo je trenutno možno samo za stranke v Ljubljani in okolici. Za druge lokacije nas kontaktirajte."* Preverjanje se osvežuje ob vsakem vnosu (oninput).
   - **Termini:** v `timeOpts` spremeni zanko iz `h=8..18` na **`h=10..14`** (začetki 10:00–14:00). V `blockedFor` odstrani blokiranje sosednjih ur — blokiraj SAMO uro dostave (`b[h]=1;` brez `h-1`/`h+1`). Popravi hint: "Zasedeni termini so onemogočeni (dostava traja 1 uro)."
   - Validacija "Naprej": zahtevaj ime, priimek, naslov, poštno, mesto, telefon, veljaven e-mail, datum, uro.
   - V `rec` (submit) dodaj `postna_stevilka: s.postna, mesto: s.mesto` (Delavec D doda stolpca).

5. **Korak 4 – Povzetek** (`viewPovzetek`):
   - Gumb "Naprej na račun" preimenuj v **"Registracija in plačilo"**.
   - Dodaj drugi gumb **"Oddaj povpraševanje"** → odpre obrazec (modal ali zamenjava pogleda): Ime, Priimek, E-pošta, Telefon (predizpolnjeno iz `s`), Vprašanje (textarea, obvezno). Ob oddaji shrani v Supabase tabelo `povprasevanja` (Delavec D) skupaj s povzetkom paketa; nato prikaži: **"Hvala! Kontaktirali vas bomo v najkrajšem možnem času."** + gumb nazaj na domačo stran. Če insert ne uspe, fallback `mailto:` z izpolnjeno vsebino.
   - V povzetek dodaj vrstici Poštna številka in Mesto.

**Sprejemni kriterij:** celoten flow deluje z `python -m http.server` lokalno; ne-ljubljanska pošta blokira online naročilo; termini samo 10:00–14:00; krhki predmeti odstranjeni; povpraševanje se shrani in prikaže potrditev.

---

## DELAVEC D — Baza + PDF račun po e-pošti

Datoteke: `Moj-profil/sql/setup.sql` (dopolni), `supabase/functions/poslji-racun/index.ts`

1. **SQL migracija** (nov razdelek v setup.sql):
   ```sql
   alter table public.narocila add column if not exists postna_stevilka text;
   alter table public.narocila add column if not exists mesto text;

   create table if not exists public.povprasevanja (
     id bigint generated by default as identity primary key,
     ime text, priimek text, email text, telefon text,
     vprasanje text not null,
     paket text, tip text,
     created_at timestamptz default now()
   );
   alter table public.povprasevanja enable row level security;
   create policy povp_insert_anon on public.povprasevanja
     for insert to anon, authenticated with check (true);
   -- (branje samo prek service_role / dashboarda)
   ```

2. **PDF račun** — nadgradi `poslji-racun/index.ts`:
   - Generiraj PDF s knjižnico `pdf-lib` (`import { PDFDocument, StandardFonts } from "https://esm.sh/pdf-lib@1.17.1"`). Vsebina: glava s podatki podjetja (spodaj), podatki kupca (ime, priimek, e-pošta, naslov če obstaja), številka računa, datum izdaje, rok plačila, tabela: opis / osnova / DDV 22 % / ZA PLAČILO, noga: "Račun je izdan v elektronski obliki in velja brez podpisa in žiga."
   - **Fiktivni podatki podjetja (place-holder, šef potrdi kasneje):**
     Rabimbox d.o.o., Tehnološki park 21, 1000 Ljubljana · ID za DDV: SI12345678 · Matična št.: 1234567000 · IBAN: SI56 1234 5678 9012 345 · info@rabimbox.si
   - PDF pripni na Resend e-mail: v body dodaj `attachments: [{ filename: "Racun-" + r.stevilka + ".pdf", content: base64Pdf }]` (base64 brez prefiksa). Obstoječi HTML e-mail ostane kot telo sporočila.
   - POZOR pri šumnikih: StandardFonts (Helvetica) ne podpira č/š/ž — ali vgradi TTF font (fontkit) ali v PDF uporabi besedila brez šumnikov (c/s/z). Izberi vgradnjo fonta, če gre gladko; sicer brez šumnikov.
3. **Deploy opomba:** funkcija teče v Supabase (potrebna `RESEND_API_KEY`, `RACUN_FROM`). Lokalno testiraj s `supabase functions serve`. To je edini del, ki ni 100 % "lokalen" — brez deploya se e-mail ne pošlje (checkout to že prenese tiho).
4. **(Zabeleženo iz prejšnjega pregleda, ne blokira tega sprinta):** kreiranje računa preseliti iz klienta v edge funkcijo — počaka na naslednji sprint, šef obveščen.

**Sprejemni kriterij:** testni klic funkcije pošlje e-mail s pripetim PDF računom z vsemi zneski (osnova/DDV/skupaj) in fiktivnimi podatki Rabimbox.

---

## Vrstni red in odvisnosti

1. Delavec D (SQL) → pred testiranjem Delavca C (stolpca + tabela povprasevanja).
2. Delavec C doda `?tip=` podporo → Delavec B jo uporabi (lahko delata vzporedno, dogovorjen format parametra).
3. Delavca A in B neodvisna.
4. Skupni test na koncu: celoten flow od domače strani → naročilo → e-mail s PDF → prikaz v panelu.
