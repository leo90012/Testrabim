# Rabimbox – Design system

Enotni vir resnice za barve, pisave, gumbe in značke. Velja za **vse tri aplikacije**:
spletna stran (`css/site.css`), naročilo (`narocilo/css/checkout.css`) in panel (`moj-profil/css/styles.css`).

## Barve

| Vloga | Koda | Uporaba |
|---|---|---|
| Primarna (CTA) | `#0067ff` | vsi glavni gumbi, aktivne povezave, poudarki |
| Primarna – hover | `#0052cc` | hover glavnih gumbov |
| Primarna – mehka | `#e8f0ff` | ozadje aktivnega menija, značke "info" |
| Akcent (sekundarni) | `#6ec1e4` | dekoracija, ikone, **nikoli** za CTA |
| Tekst | `#141a29` / `#2a3342` | naslovi in glavno besedilo |
| Nevtralno sivo | `#5b6472` / `#7b8794` | pomožno besedilo, **neaktivna** stanja |
| Zelena (uspeh) | `#00a32a` | "Plačano", "Aktivna", "Dostavljeno" |
| Jantarna (dejanje) | `#b7791f` | "Ni plačano", "Oddano", "Na poti" |
| Rdeča | `#d92d20` | **samo napake** in zapadli računi |

Pravilo: rdeča je rezervirana za napake in zapadlost. Neaktivna/preklicana stanja so **siva**, ne rdeča.

## Pisave

- Naslovi: **Space Grotesk** (500/600/700)
- Besedilo: **Inter** (400/500/600/700)
- Brez velikih tiskanih črk in razpiranja v naslovih.

## Gumb (ena komponenta, tri stanja)

- **Normalno:** ozadje `#0067ff`, bela pisava, radij 10px, mehka modra senca.
- **Hover:** ozadje `#0052cc`, dvig za 1–2px, izrazitejša senca.
- **Klik:** `scale(.98)`.
- **Onemogočeno:** enaka oblika, `opacity .45`, brez sence in dviga (ne siva škatla).
- Sekundarni: ghost/outline (bela ali prosojna, moder tekst) — brez sence.

## Značke (badge)

`gray` (nevtralno/neaktivno) · `green` (uspeh) · `blue` (info) · `amber` (v teku/dejanje) · `red` (napaka).

## Prazna stanja

Ikona v krogu + kratek naslov + ena vrstica pojasnila + (po potrebi) en glavni CTA.
Nikoli le gola siva vrstica besedila.

## Animacije

- Prehod med koraki / razkrivanje ob drsenju: fade + `translateY` ~10–20px, 150–250 ms.
- Vse spoštuje `prefers-reduced-motion`.
