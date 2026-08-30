# Povezava spletne strani in skladiščne aplikacije – ocena in načrt

Vodja projekta, 3. 8. 2026. Pregledal: `RABIMBOX-SKLADISCE` (index.html, app.js 424 vrstic, config.js) + živ podatkovni model v Supabase.

## Kratka ocena

Aplikacija je dobro narejena in — kar je najpomembneje — **že uporablja isto bazo kot spletna stran**. Verižica `narocilo → narocnina → škatle` v bazi **deluje**: naročilo #9 (izposoja, 40 boxov) je ustvarilo naročnino #5 in rezerviralo 40 škatel. To je bistvo integracije in je že postavljeno.

Kar manjka, ni tehnična povezava, ampak **pretok dela v obe smeri**. Trenutno je enosmeren: naročilo pade v bazo, škatle se rezervirajo, a skladiščnik o tem ne izve, stranka pa ne vidi, kaj se z njenimi škatlami dogaja.

Arhitekturno sta sistema pravilno ločena: stranke berejo tabele prek RLS, osebje prek `sklad_*` RPC funkcij (`sklad_boxi`, `sklad_dogodki`, `sklad_update_box`). To je dobra zasnova — ohrani jo.

---

## Kaj je treba narediti

### 1. Skladiščnik mora videti naročila strank (največja vrzel)

Danes v aplikaciji obstajata samo zavihka **Škatle** in **Zgodovina**. Nikjer ni:

- **`narocila`** — nova naročila iz checkouta (kdaj dostaviti, na kateri naslov, koliko boxov, stopnice, pomoč pri polnjenju);
- **`zahteve_dostave`** — zahteve iz panela "Moj profil" (dostava/prevzem/vrnitev). Stranka odda zahtevo, ta obleži v bazi in nihče je ne obdela. V bazi so 4 take zahteve s statusom `nova`.

**Rešitev:** dodaj zavihek **"Naročila"** (ali "Za danes"), ki združi oba vira v en delovni seznam, urejen po datumu dostave, z gumbi za spremembo statusa (`nova → potrjena → v izvajanju → zaključena`). Potrebna bo nova RPC funkcija `sklad_zahteve()` in `sklad_update_zahteva()` po vzoru obstoječih.

### 2. Poenoti statuse in jih prevedi za stranko

Skladiščna aplikacija uporablja 8 internih statusov (`na_zalogi`, `rezervirana`, `pri_stranki`, `v_skladiscu`, `v_transportu`, `zasedena`, `poskodovana`, `umaknjena`). Panel za stranke pa jih prikazuje surovo — stranka vidi značko **"rezervirana"**, kar ji nič ne pove (vseh 100 škatel v bazi ima ta status).

**Rešitev:** en sam slovar statusov, ki velja za oba sistema, in prevod za stranko:

| Interni status | Kaj vidi stranka |
|---|---|
| `na_zalogi`, `rezervirana` | Pripravljeno za dostavo |
| `v_transportu` | Na poti |
| `pri_stranki`, `zasedena` | Pri vas |
| `v_skladiscu` | V skladišču |
| `poskodovana`, `umaknjena` | (skrij iz pogleda stranke) |

Poleg tega poenoti `status_narocnine` v `kupci` — v bazi so mešane vrednosti "aktivna" in "Neaktiven".

### 3. Datumi naročnine – en vir resnice

`narocnine.datum_do` je **prazen** pri obeh naročninah, `kupci.datum_konca_narocnine` pa je prazen pri vseh 9 strankah. Zato skladiščna aplikacija v stolpcu "Velja do" kaže "–", panel pa "Naročnina do: -".

**Rešitev:** `narocnine.datum_od/datum_do` naj bo edini vir. Ob ustvarjanju naročnine nastavi `datum_do` (npr. +1 mesec ob izposoji, +3 mesece minimalno pri skladiščenju). Panel in skladiščna aplikacija naj oba berete iz `narocnine`, `kupci.datum_konca_narocnine` pa opusti ali osveži s triggerjem.

### 4. Lokacije škatel

`skatle.lokacija_id` obstaja, tabela **`lokacije` pa ne obstaja**, in vseh 100 škatel je brez lokacije. Skladiščna aplikacija ima polje "Lokacija (oznaka)" in `sklad_update_box` sprejema `p_lokacija_koda` — torej je bila zamišljena.

**Rešitev:** ustvari tabelo `lokacije` (regal, polica, koda tipa `A-01-03`) ali pa opusti `lokacija_id` in obdrži samo tekstovno `lokacija`. Brez tega skladiščnik ne ve, kje škatla fizično je — kar je glavni smisel skladiščne aplikacije.

### 5. Zgodovina se ne polni

Tabela `dnevnik_dejanj` je **prazna**, čeprav ima aplikacija zavihek "Zgodovina" in je bilo že več sprememb škatel. `sklad_update_box` očitno ne piše dnevnika.

**Rešitev:** trigger na `skatle` (ali vpis znotraj `sklad_update_box`), ki ob vsaki spremembi statusa/lokacije/lastnika zapiše vrstico z uporabnikom in časom.

### 6. Aplikacijo objavi na splet

README pravi "odpri index.html z dvoklikom". Prek `file://` **skener kamere ne deluje** (aplikacija to sama javi) in vsak skladiščnik ima svojo kopijo. Objavi jo na `https://skladisce.rabimbox.si` (Netlify/Vercel/Cloudflare Pages, ista mapa) — takrat dela skener na telefonu, kar je za skladišče ključno.

### 7. Prijava osebja

Uporabniško ime se v JS preslika v e-pošto, admin pa se določa s primerjavo `email === "admin@rabimbox.si"` v brskalniku. Vsebinski nadzor je sicer v bazi (`is_staff`/`is_admin`), kar je prav — a preveri, da RPC funkcije res zavrnejo navadnega uporabnika. **Testiraj: prijavi se kot stranka in poskusi klicati `sklad_boxi`** — mora vrniti napako, ne podatkov.

Gesli sta zapisani v `README.txt` v repozitoriju — odstrani ju od tam in ju hrani v upravitelju gesel.

---

## Dve manjši, a pomembni opažanji

- **Deployana verzija je novejša od lokalne mape.** Panel na GitHub Pages že uporablja stolpec `placano` in tabelo `narocnine`; lokalni repozitorij je bil medtem tudi posodobljen (`a6be608`), a se prepričaj, da sta usklajena, preden kdo dela naprej.
- **Panel bere naročila po e-pošti** (`narocila.email`), baza pa jih veže po `kupec_id`. Če stranka spremeni e-naslov ali naroči kot gost z drugim, naročila izginejo iz njenega pogleda. Poizvedbo preusmeri na `kupec_id`.

---

## Priporočen vrstni red

1. **RLS popravki** iz `NAVODILA-BAZA.md` — dokler prijavljena stranka vidi vse kupce, ostalo ni pomembno.
2. **Zavihek "Naročila" v skladiščni aplikaciji** (točka 1) — brez tega sistema ne moreta delovati skupaj.
3. Statusi in datumi naročnin (2 in 3) — poenotenje jezika med sistemoma.
4. Objava aplikacije na https + lokacije + dnevnik (6, 4, 5).

Ko bo to postavljeno, bo pot naročila sklenjena: stranka naroči na spletni strani → skladiščnik vidi naročilo in ga potrdi → skenira škatle in jim dodeli lokacijo → stranka v panelu vidi status svojih škatel in datum naročnine.
