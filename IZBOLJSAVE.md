# Rabimbox – seznam potencialnih izboljšav in dodatkov

Pregledano: statični export strani (WP/Elementor), checkout `narocilo/`, panel `Moj-profil/`, Supabase (RLS + edge funkcija `poslji-racun`) in živa stran rabimbox.si.

## 1. Visoka prioriteta (prodaja in varnost)

1. **Kontaktni podatki manjkajo.** Na domači strani ni telefonske številke, `tel:`/`mailto:` povezav niti kontaktnega obrazca (0 obrazcev). Dodaj kontaktno sekcijo + telefon v glavo strani. Razmisli o WhatsApp gumbu.
2. **Gumb "Naroči zdaj" na živi strani ni v navigaciji.** Lokalna verzija ga ima, živa (rabimbox.si) ne. Objavi novo verzijo in dodaj izstopajoč CTA gumb v meni in nad pregibom.
3. **Plačilo v checkoutu.** Trenutno "Stripe bo dodan kmalu" – račun se izda brez plačila. Integriraj Stripe (ali vsaj UPN QR na računu za slovenski trg).
4. **Varnostna luknja – tabela `racuni`.** Checkout vpisuje račune neposredno iz brskalnika z anon ključem; edge funkcija `poslji-racun` nima avtentikacije (CORS `*`, sprejme poljubno `stevilka`). Kdorkoli lahko generira lažne račune in sproža pošiljanje e-pošte. Rešitev: kreiranje računa + pošiljanje prenesi v eno edge funkcijo (service role), klient naj samo odda naročilo.
5. **Zaščita pred spamom naročil.** Vpis v `narocila` je odprt za anon – dodaj honeypot/captcho (npr. Cloudflare Turnstile) in rate limiting.
6. **Obvestilo lastniku ob naročilu.** Edge funkcija pošlje e-pošto samo stranki. Dodaj kopijo/obvestilo na info@rabimbox.si (ali Slack/Telegram), da ne zamudiš naročila.
7. **Neskladje shem `racuni`.** Checkout vpisuje stolpce (`osnova`, `ddv`, `email`, `ime`...), ki jih zakomentirana shema v `sql/setup.sql` nima; račun tudi nima `kupec_id`, panel pa jih filtrira po `kupec_id` → računi se stranki v panelu ne prikažejo. Uskladi shemo in ob vpisu poveži `kupec_id`.

## 2. SEO in deljenje

8. **Meta description manjka** na domači strani; dodaj unikatne opise na vse strani.
9. **Open Graph / Twitter card oznak ni** (0) – ob deljenju na FB/LinkedIn ni slike in opisa.
10. **Schema.org (JSON-LD) manjka** – dodaj `LocalBusiness`, `Service`, `FAQPage` in `AggregateRating` (imaš Trustindex ocene).
11. **`sitemap.xml` in `robots.txt` manjkata** v statičnem exportu.
12. **Blog razširi** – samo 2 objavi. Ključne besede: "selitev Ljubljana", "najem škatel za selitev", "skladiščenje na zahtevo cena" ipd.
13. **Angleška verzija** – slugi v `/en/` so še slovenski (npr. `/en/skladiscenje/`), preveri hreflang oznake in kakovost prevoda.

## 3. Tehnično čiščenje in hitrost

14. **Ostanki WP exporta:** `xmlrpc.php`, `wp-json/`, `comments/feed/`, podvojene `indexXXXX.html` datoteke – odstrani, mešajo crawlerje.
15. **Teža strani:** 169 KB HTML, 17 CSS datotek, 28 skript (Elementor). Združi/minimiziraj, slike pretvori v WebP, samo-gosti Google fonte.
16. **Prazni `alt` atributi** na slikah – dopolni (dostopnost + SEO).
17. **Footer "©2024"** – posodobi na tekoče leto (ali dinamično).
18. **Politika zasebnosti** – cookie notice se sklicuje nanjo, samostojne strani pa ni (samo Pravila in pogoji). Dodaj (GDPR).

## 4. UX in konverzija

19. **Kalkulator cene na domači strani / ceniku** – interaktivni izračun ("koliko boxov potrebujem za 2-sobno stanovanje") z gumbom naravnost v checkout.
20. **FAQ sekcija** na domači strani in v checkoutu (min. obdobje, dostava, kaj sme v box, zavarovanje...).
21. **Sekcija "Kako deluje" v 3 korakih** z ikonami/fotkami (dostavimo → napolniš → skladiščimo/vrnemo).
22. **Prave fotografije** boxov, kombija, skladišča namesto ilustracij – zaupanje.
23. **Checkout: shrani stanje** v `sessionStorage`, da ob osvežitvi strani uporabnik ne začne znova.
24. **Checkout: validacija telefona in e-pošte** sproti (ne šele z `alert()` – zamenjaj alert-e z inline sporočili).
25. **Območje dostave** – zemljevid ali seznam krajev, ki jih pokrivaš (+ poštna številka check v checkoutu).

## 5. Panel Moj profil (dodatki)

26. **PDF računi** – generiraj PDF (v edge funkciji) in shrani v Supabase Storage; povezava v panelu in e-pošti.
27. **Fotografije boxov** – stranka ob oddaji vidi fotografijo/oznako vsebine svojega boxa ("kaj imam v boxu 12?").
28. **Statusna obvestila** – e-pošta ob potrditvi termina, dan pred dostavo (Resend že imaš).
29. **Sprememba/preklic termina** iz panela.
30. **Admin pogled** – preprosta interna stran za pregled naročil, terminov in statusov (trenutno verjetno delaš direktno v Supabase tabelah).

## 6. Rast (kasneje)

31. Google Business profil + zbiranje ocen (povezava po opravljeni dostavi).
32. Newsletter / e-mail za zapuščene checkoute.
33. Priporočilni program ("pripelji prijatelja – 1 mesec popusta").
34. Poslovni paket B2B (arhivi, sejemska oprema, pisarne) kot ločena pristajalna stran.
