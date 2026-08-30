# Pregled Supabase – stanje in kaj je še treba dodati

Pregledano v nadzorni plošči projekta *Rabimbox* (`lvfnumhirarpshpqyoay`), 5. 8. 2026.
Vse poizvedbe so bile samo za branje; ničesar nisem spreminjal.

## Dobra novica: uhajanje podatkov je odpravljeno

Prijavljena stranka zdaj prek API-ja vidi **samo svoje** podatke — preverjeno v živo:
1 kupec (prej 9), 100 škatel (prej 1003), 2 naročili, 2 računa. Skladiščne tabele
(`skladisce_lokacije`, `skladisce_dogodki`, `dnevnik_dejanj`) so za stranko zaprte.
Politike so postavljene na vseh 11 tabelah in so smiselno napisane.

---

## 1. Nujno: vsak se lahko registrira kot skladiščnik ali administrator

Tri stvari se nesrečno sestavijo:

- `is_staff()` in `is_admin()` presojata **samo po e-poštni domeni `@rabimbox.si`** (potrjeno: funkciji sta dolgi 103 znake, ne uporabljata ne tabele osebja ne metapodatkov);
- **Confirm email = IZKLOPLJENO** (Authentication → Sign In / Providers);
- **Allow new users to sign up = VKLOPLJENO**.

Posledica: kdorkoli se registrira z naslovom tipa `karkoli@rabimbox.si` in **takoj**
dobi veljavno sejo s pravicami osebja — vidi vse stranke, njihove e-naslove, telefone
in vseh 1003 škatel, administrator pa lahko škatle tudi ureja. E-naslova mu ni treba
imeti v lasti, ker potrditve ni.

**Kaj narediti (v tem vrstnem redu):**

1. Vklopi **Confirm email** (takojšnja delna zapora).
2. Zamenjaj presojo z eksplicitnim seznamom:
   ```sql
   create table if not exists public.osebje (
     user_id uuid primary key references auth.users(id) on delete cascade,
     vloga text not null check (vloga in ('skladiscnik','admin')),
     created_at timestamptz default now()
   );
   alter table public.osebje enable row level security;  -- brez politik = nihče ne bere

   create or replace function public.is_staff() returns boolean
   language sql stable security definer set search_path=public as $$
     select exists (select 1 from public.osebje where user_id = auth.uid());
   $$;

   create or replace function public.is_admin() returns boolean
   language sql stable security definer set search_path=public as $$
     select exists (select 1 from public.osebje where user_id = auth.uid() and vloga='admin');
   $$;
   ```
   Nato ročno vpiši obstoječe tri račune `@rabimbox.si` v tabelo `osebje`.
3. Razmisli o izklopu prostih registracij, če stranke račun tako ali tako dobijo ob naročilu.

## 2. Nobena Edge funkcija ni objavljena

Zavihek Edge Functions je prazen — piše "Deploy your first Edge Function". To pomeni,
da funkcija `poslji-racun` (skupaj z delom za PDF račun) **nikoli ni bila objavljena** in
da stranke **niso prejele nobenega računa po e-pošti**. Checkout to tiho prenese in
izpiše "Račun je shranjen; e-pošto s podatki pošljemo po potrditvi".

Potrebno: `supabase functions deploy poslji-racun` + skrivnosti `RESEND_API_KEY` in
`RACUN_FROM` (Edge Functions → Secrets). Brez tega je delo s PDF računom neuporabljeno.

## 3. Brskalnik še vedno lahko ustvarja račune

Politika `racuni_insert` dovoljuje vpis vlogama `anon, authenticated` z `with check (true)`.
Kdorkoli z javnim ključem lahko ustvari poljuben račun. To je točka D2 iz prejšnjih navodil
in še ni rešena — izdajo računa je treba prenesti v Edge funkcijo s service-role ključem.

## 4. Skladišče ne ve, kje so škatle

Tabela `skladisce_lokacije` obstaja, a je **prazna (0 vrstic)**, in **vseh 1003 škatel**
ima `lokacija_id` prazen. Skladiščna aplikacija ima polje za lokacijo, a ga ni s čim
napolniti. Brez tega skladiščnik fizično ne najde škatle — kar je glavni namen aplikacije.

Potrebno: vpisati regale/police (npr. `A-01-03`) in ob skeniranju dodeljevati lokacijo.

## 5. Moja skripta `integracija.sql` še ni pognana

Preverjeno: `sklad_zahteve`, `sklad_zahteva_skatle`, `sklad_update_zahteva`, `sklad_stevci`,
`rb_trajanje` in pogled `moje_skatle` v bazi **ne obstajajo**. Dokler skripte ne poženeš:

- nov zavihek **Naročila** v skladiščni aplikaciji javi napako,
- statusi ostanejo neenotni,
- datumi naročnin ostanejo prazni.

Trenutno stanje, ki ga skripta popravi:

| Kaj | Zdaj v bazi |
|---|---|
| Statusi škatel | `na_zalogi` 780, `rezervirana` 220, **`zasedena` 3** (opuščena vrednost) |
| Statusi zahtev | `nova` 2, **`v obdelavi` 2** (prosto besedilo s presledkom) |
| Naročnine brez `datum_do` | **5 od 5** |
| Kupci brez `datum_konca_narocnine` | **9 od 9** |

## 6. Povpraševanja obležijo brez odziva

V tabeli `povprasevanja` sta **2 zapisa**, za katera ni bil nihče obveščen — ni ne
e-poštnega obvestila ne pogleda v kateri koli aplikaciji. Stranki, ki sta ju oddali,
čakata na odgovor.

Potrebno: obvestilo na `info@rabimbox.si` (database webhook ali Edge funkcija) in
zavihek za pregled — smiselno kar poleg novega zavihka Naročila.

## 7. Manjše, a moteče

- **Vseh 7 računov ima `narocilo_id` prazen** — računa ni mogoče povezati z naročilom, kar
  otežuje sledenje plačilom. Trigger `racun_link_kupec` poveže kupca, ne pa naročila.
- **780 škatel brez kupca** je prosta zaloga (v redu), 220 rezerviranih, 3 pri strankah.
- 3 računi osebja obstajajo in so potrjeni; skupno 9 uporabnikov.
- V bazi je 8 prožilcev, ki že delajo dobro delo (samodejno dodeljevanje škatel naročilu,
  ustvarjanje kupca, bar kode, številke strank) — te pusti pri miru.

---

## Priporočen vrstni red

1. **Vklopi Confirm email** (ena kljukica, takoj).
2. **Tabela `osebje` + novi `is_staff`/`is_admin`** (točka 1).
3. **Poženi `integracija.sql`** (točka 5) — s tem zaživi zavihek Naročila.
4. **Objavi `poslji-racun`** in dodaj skrivnosti (točka 2).
5. Izdaja računov na strežnik (točka 3) in obvestila o povpraševanjih (točka 6).
6. Napolni lokacije skladišča (točka 4).
