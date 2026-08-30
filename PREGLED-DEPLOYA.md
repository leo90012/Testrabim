# Pregled deploya https://leo90012.github.io/Rabimb/ (27. 7. 2026)

Preverjeno v živo: vseh 12 strani, vsi linki (0 × 404), celoten checkout flow, prijava v Moj profil, cookie banner.

## Deluje ✓

- Vse strani in navigacija (header + footer), Moj profil / Naroči zdaj v footerju desno
- Izposoja & Skladiščenje: cenik, gumb "Naroči zdaj", link na Cenik
- Cenik: tel. in e-mail klikabilna; Blog: obe objavi, brez WP ostankov
- Checkout: ozadje na izbiri, brez "krhkih predmetov", vsa nova polja, Maribor → "Kontaktiraj nas" + opozorilo, Ljubljana → Naprej, termini 10:00–14:00 (živ Supabase RPC), gumba "Oddaj povpraševanje" + "Registracija in plačilo", predizpolnjeni podatki
- Moj profil: neplačana naročila + "Izberi vsa neplačana" (89,00 €), kartici Izposoja/Skladiščenje s štetjem boxov, boxi kot "Box #ID" brez barkod, "Izberi vse v skladišču" (60), Naročila, Računi (2 računa se prikažeta!), Profil
- Cookie "Dovoli" deluje in skrije banner

## Popraviti (po prioriteti)

1. **Mnenja strank so prazna (edina prava napaka).** Trustindex skripta se nalaga z `leo90012.github.io/cdn.trustindex.io/...` — manjka `/Rabimb/` v poti → 404 → sekcija "Kaj pravijo naše stranke" je prazna bela luknja na domači strani. Rešitev: popravi `src` v relativno pot ALI sekcijo nadomesti s 3 statičnimi mnenji (hitreje, brez zunanje odvisnosti).
2. **Kontakt na Ceniku:** sekcija "Rezerviraj svoje boxe" (telefon + e-mail) je v nasprotju z navodilom "kontakt samo na O nas" — odstrani ali potrdi izjemo.
3. **O nas:** e-mail in telefon sta navadno besedilo — naredi ju klikabilna (`mailto:` / `tel:`).
4. **Panel – "Naročnina do: -"** pri vseh boxih (kupec nima datuma v bazi). Vpiši datum v `kupci.datum_konca_narocnine` ali skrij besedilo, ko ni podatka.
5. **Panel – Računi:** račun z zapadlostjo 22. 07. je pretekel, a kaže "izdan" — status "zapadlo" prikaži samodejno, ko je `datum_zapadlosti < danes`.
6. **Panel – Profil:** polje Naslov (ulica) je skrito — stranka ga ne more urediti, čeprav ga checkout zbira. Vrni vidno polje.
7. **Gumb "Plačilo izbranih"** samo izpiše "Stripe kmalu". Dokler plačila ni, prikaži podatke za nakazilo (IBAN + sklic z računa) — sicer je gumb neuporaben element.
8. **Počasen prvi load** checkouta in panela (spinner ob Supabase init; enkrat je stran celo zamrznila). Dodaj timeout z jasnim sporočilom in `defer`/preload za skripte.

## Počistiti (neuporabne datoteke v repo — niso linkane, a so smeti)

- `xmlrpc.php`, `xmlrpc0db0.php`, mape `wp-json/`, `comments/`, `feed/`, `www.googletagmanager.com/`, podvojene `indexXXXX.html` v korenu
- GTM/Site Kit skripte: analitika na GitHub Pages ne deluje (container mrtev) — odstrani ali zamenjaj z GA4 za to domeno
- Footer "©2024" → 2026 (ali dinamično leto)

## Dodati (manjka za resen nastop, ko bo na pravi domeni)

- Meta description + Open Graph oznake (deljenje na FB/IG pokaže prazno)
- `sitemap.xml`, `robots.txt`, favicon je OK
- Politika zasebnosti (cookie banner se sklicuje nanjo, strani pa ni)
