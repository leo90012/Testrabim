# Stripe: plačilo in podaljšanje na 30 dni

## 23. 10. 2026 – samodejna bremenitev na 30 dni

- Checkout (`rapid-api`, source `supabase/functions/stripe-checkout/index.ts`) plača prvo obdobje in ob izrecnem soglasju shrani kartico za prihodnja plačila. Ločeno soglasje k registraciji ne vključuje samodejnega plačevanja.
- Nova funkcija `rb-billing` ustvari naročnino Stripe s ponavljanjem `day / 30`; prvo že plačano obdobje se ne bremeni še enkrat. Začetek je datum dostave, konec je izključujoč. Na računu se izpiše zadnji vključeni dan (konec minus en dan).
- Webhook v tem projektu je **`Stripe-webhook`** (velika začetnica). Podpis Stripe se preveri v kodi. Obravnava checkout, invoice.created, invoice.paid, payment_failed, payment_action_required in subscription.deleted. Dogodki so zabeleženi in se obdelajo idempotentno.
- Pet dni pred obnovo se pošlje opomnik. Cron `rabimbox-billing-30dni` kliče zasebni worker prek ključa v Vault. Pravočasno naročeno vračilo vseh boxov do konca obdobja ustavi naslednjo obnovo; fizična obdelava v skladišču je lahko poznejša. Delno vračilo spremeni naslednji paket brez poračuna nazaj.
- Plačani računi imajo nespremenljiv posnetek obdobja/opisa. Prvo plačilo pošlje eno potrditev s PDF priponko, obnova eno sporočilo s PDF. Kontakt na računu je info@rabimbox.si. Stripe pri vrstici naročnine sam izpiše obdobje; celoten slovenski opis je tudi v memo polju računa.
- Ročna naročila ostanejo ročna, dokler lastnik v profilu ne potrdi vključitve kartice. Admin vidi stanje plačila ločeno od logističnega statusa.

### Migracije, uporabljene v tem projektu

1. `supabase/sql/2026-10-23-billing.sql`
2. `supabase/sql/2026-10-23-billing-followup.sql`
3. `supabase/sql/2026-10-23-test-contact-guard.sql`
4. `supabase/sql/2026-10-23-queue-fix.sql`
5. `supabase/sql/2026-10-23-strict-order-boxes.sql`

Test baze: `2026-10-23-billing-tests.sql` se konča z ROLLBACK in pokriva periodiko, vračila, zapiranje prevozov, pravice, ponovljene in stare dogodke ter nespremenljivost računov.

### Testni način in prehod na prava plačila

Ob namestitvi je bil obstoječi Stripe ključ **testni**. Testni naročili TEST-20261023-MIHA in TEST-20261023-MATIC uporabljata samo Stripe testne kartice in testni uri; ne zasedata fizičnih boxov in ne izdajata pravih računov. Skrbniški `test_control` deluje samo za naročila is_test s pripeto testno uro in preverjenim testnim ključem. Če bo primarni ključ pozneje produkcijski, za teste ohranite ločen STRIPE_TEST_SECRET_KEY.

Pred pravimi bremenitvami mora lastnik v Stripe/Supabase sam vnesti produkcijske ključe in podpis webhooka ter preveriti nastavitve samodejnih Stripe e-mailov/računov, da ne podvajajo potrditve Rabimbox. Produkcijskih kartic testni scenariji ne uporabljajo. Ključi se ne hranijo v repozitoriju.

### Dovoljenja

`rb-billing` ima preverjanje prijave in administratorske vloge v kodi; stari prehodni JWT filter je za to funkcijo izključen s potrditvijo lastnika. Cron in dogodki zahtevajo strežniški ključ. Stranke lahko upravljajo samo lastno kartico; dnevnik pošte in izvoz zahtevata vlogo admin.

### Stanje objave in preverjanja

Vseh šest funkcij in oba vmesnika sta objavljena. Po potrditvi lastnika je `enabled=true`; primarni Stripe ključ ostaja TEST. Pri Maticu je bila preverjena sprememba 40 → 20 boxov (109 → 69 EUR), uspešna obnova, zavrnjena kartica in uspešen ponovni poskus. Pri Mihi je bila preverjena obnova za 69 EUR. Opomnika in PDF priponke sta evidentirana brez podvojenih sporočil.

Pred prehodom na live je poleg ključev treba v Stripe preveriti podatke izdajatelja, naslov in davčno številko, jezik ter samodejne e-maile. Testni račun namenoma nosi oznako sandbox. `invoice.description` in footer vsebujeta dogovorjeno obdobje ter info@rabimbox.si.
