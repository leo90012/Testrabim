# NAVODILA ZA DELAVCE – Povezave z bazo (Supabase)

Vodja projekta, 27. 7. 2026. Osnova: živ test deploya `leo90012.github.io/Rabimb/` proti produkcijski bazi `lvfnumhirarpshpqyoay`.

## Kaj sem preveril in kaj sem našel

Popis vseh klicev na bazo v deployani kodi:

| Kje | Tabela / klic | Kdo kliče |
|---|---|---|
| Checkout | `narocila.insert`, `racuni.insert`, `povprasevanja.insert`, `kupci.select`, rpc `zasedeni_termini`, fn `poslji-racun` | anon (neprijavljen obiskovalec) |
| Panel | `kupci.select/update`, `skatle.select`, `zahteve_dostave.select/insert`, `zahteve_dostave_skatle.insert`, `narocila.select`, `racuni.select` | prijavljen uporabnik |

Rezultati testov:

- **Anonimni obiskovalec ne more brati nobene tabele** (0 vrstic povsod) — RLS je vklopljen in to je dobro.
- **Prijavljen uporabnik vidi PREVEČ.** Z računom `maticking31@gmail.com` sem prek API-ja prebral **vseh 9 zapisov v `kupci`, vključno z e-naslovi vseh strank**, in **vseh 1003 vrstic v `skatle`** (panel jih v vmesniku sicer filtrira na 100, a filter je samo v JS — API ga ne uveljavlja). To je **uhajanje osebnih podatkov (GDPR)** in najbolj nujna postavka.
- `povprasevanja` obstaja in anon vpis deluje (potrjeno z nedestruktivnim testom) — pravilno, a **brez zaščite pred spamom**.
- Podatki: `kupci.datum_konca_narocnine` je `null` pri vseh 9 strankah (zato "Naročnina do: -"); `narocila` starejša od današnjih nimajo `postna_stevilka`/`mesto` (pričakovano, stolpca sta nova); račun `RB-2026-09905845` je zapadel 22. 7., a ima še status `izdan`.

---

## DELAVEC D1 — RLS (NUJNO, najprej)

Cilj: prijavljen uporabnik vidi samo svoje podatke.

1. V Supabase → Authentication → Policies preglej tabeli **`kupci`** in **`skatle`**. Ker sta politiki iz `sql/setup.sql` napisani pravilno (`using (lower(email) = lower(auth.jwt()->>'email'))` oz. `kupec_id = my_kupec_id()`), a v praksi vidim vse, je vzrok ena od dveh možnosti — preveri obe:
   - poleg naše politike obstaja **še ena permisivna politika** (npr. "Enable read access for all users" z `using (true)`) — permisivne politike se seštevajo, zato ena preširoka izniči vse ostale. Take politike **izbriši**;
   - ali `setup.sql` na tej bazi ni bil pognan v celoti.
2. Zaženi kontrolno poizvedbo in mi pošlji izpis:
   ```sql
   select tablename, policyname, cmd, roles, qual
   from pg_policies where schemaname='public' order by tablename;
   select relname, relrowsecurity from pg_class
   where relname in ('kupci','skatle','narocila','racuni','zahteve_dostave','zahteve_dostave_skatle','povprasevanja');
   ```
3. **Manjkajoči RLS za `narocila` in `racuni`** — v `setup.sql` ju ni med `enable row level security`. Dodaj:
   ```sql
   alter table public.narocila enable row level security;
   alter table public.racuni   enable row level security;

   -- oddaja naročila iz checkouta (neprijavljen kupec)
   drop policy if exists narocila_insert_anon on public.narocila;
   create policy narocila_insert_anon on public.narocila
     for insert to anon, authenticated with check (true);

   -- stranka vidi samo svoja naročila
   drop policy if exists narocila_select_own on public.narocila;
   create policy narocila_select_own on public.narocila
     for select to authenticated
     using ( lower(email) = lower(auth.jwt() ->> 'email') );

   -- računi: samo branje svojih; vpisovanje NE iz brskalnika (glej D2)
   drop policy if exists racuni_select_own on public.racuni;
   create policy racuni_select_own on public.racuni
     for select to authenticated
     using ( kupec_id = public.my_kupec_id()
             or lower(email) = lower(auth.jwt() ->> 'email') );
   ```
4. **Preveri tudi UPDATE politike** (nisem jih testiral, ker nočem pisati v produkcijo): prijavljen uporabnik ne sme urejati tuje vrstice v `kupci`. Politika `kupci_update_own` mora imeti tako `using` kot `with check`.
5. **Test po popravku:** prijavi se kot testni uporabnik in v konzoli poženi `fetch` na `/rest/v1/kupci?select=*` — mora vrniti **točno 1 vrstico**, `skatle` pa samo boxe tega kupca. Javi mi obe številki.

**Sprejemni kriterij:** prijavljen uporabnik prek API-ja vidi 1 kupca in samo svoje škatle; anon še naprej 0 vrstic povsod.

---

## DELAVEC D2 — Izdaja računov na strežnik

Trenutno **brskalnik z javnim anon ključem sam vpisuje v `racuni`** (checkout.js, `sb.from("racuni").insert(racun)`) in nato kliče `poslji-racun` samo s številko računa. Kdorkoli lahko z anon ključem ustvari lažen račun ali sproži pošiljanje e-pošte za tuj račun.

1. Naredi novo edge funkcijo **`ustvari-racun`** (service role), ki: prejme `narocilo_id`, prebere naročilo iz baze, **sama izračuna** osnovo/DDV/znesek (nikoli iz klienta), poišče `kupec_id` po e-pošti, vstavi vrstico v `racuni` in nato pokliče obstoječo logiko za PDF + e-pošto.
2. V `checkout.js` odstrani `racuni.insert` in izračun zneskov; namesto tega en klic `sb.functions.invoke("ustvari-racun", { body: { narocilo_id } })`. Prikaz na zaključnem zaslonu naj uporabi podatke, ki jih vrne funkcija.
3. V `poslji-racun` odstrani možnost klica po `stevilka` iz brskalnika (naj bo interna/`service_role` only).
4. **`racuni.kupec_id`** naj vedno nastavi funkcija (danes je pri obstoječih zapisih nastavljen, a checkout ga ne pošilja — zanašamo se na srečo).

**Sprejemni kriterij:** iz brskalnika ni mogoče vpisati v `racuni`; oddaja naročila še vedno ustvari račun in pošlje PDF.

---

## DELAVEC D3 — Zaščita pred spamom in obvestila

1. **Rate limiting / captcha** na `narocila.insert` in `povprasevanja.insert` — trenutno lahko bot ustvari neomejeno zapisov. Vklopi Cloudflare Turnstile ali Supabase Auth CAPTCHA (Project Settings → Auth → Bot protection) in polje honeypot v obeh obrazcih.
2. **Obvestilo lastniku:** ob novem naročilu in ob novem povpraševanju naj gre e-pošta na `info@rabimbox.si` (razširi edge funkcijo ali dodaj database webhook). Danes povpraševanje pade v tabelo in nihče ne ve zanj.
3. Dodaj `status` stolpec v `povprasevanja` (`novo | v obdelavi | zakljuceno`), da se da slediti.

---

## DELAVEC D4 — Podatki in prikaz

1. **`kupci.datum_konca_narocnine` je prazen pri vseh 9 strankah** → v panelu piše "Naročnina do: -". Izberi eno: (a) vpiši datume v bazo, (b) izračunaj iz naročila (datum dostave + obdobje paketa), ali (c) skrij besedilo, ko je vrednost prazna. Priporočam (b) + (c) kot varovalo.
2. **Zapadli računi:** račun z rokom 22. 7. še vedno kaže "izdan". Dodaj v panel logiko: če `datum_zapadlosti < danes` in status ni plačan → prikaži rdečo značko "zapadlo". Idealno tudi nočni job, ki status posodobi v bazi.
3. **`status_narocnine` ni poenoten** — v bazi so vrednosti "aktivna" in "Neaktiven" (različna oblika in spol). Poenoti na `aktivna` / `neaktivna` / `preklicana` in po potrebi dodaj `check` constraint.
4. **`skatle` ima 1003 vrstic** — preveri, ali so vse prave ali gre za testne podatke iz uvoza; počisti, kar ne spada.

---

## Vrstni red

D1 (RLS) je blokada za vse ostalo — dokler ni rešen, uhajajo e-naslovi strank. Nato D2 (računi), potem D3 in D4 vzporedno.
