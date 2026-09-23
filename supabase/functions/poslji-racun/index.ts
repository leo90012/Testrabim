// Rabimbox – Supabase Edge Function: poslji-racun
// Vrne PDF plačanega računa za stranko ali notranjo potrditveno e-pošto.
//
// Vhod (POST JSON):
//   { stevilka: "RB-...", download: true }
//
// SUPABASE_URL in SUPABASE_SERVICE_ROLE_KEY sta na voljo samodejno.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import fontkit from "https://esm.sh/@pdf-lib/fontkit@1.1.1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const LOGO = "https://rabimbox.si/wp-content/uploads/2024/08/cropped-3-270x270.png";

// Podatki podjetja
const FIRMA = {
  naziv: "Rabim d.o.o.",
  naslov: "Proletarska cesta 4, 1000 Ljubljana",
  ddv: "SI45163260",
  matica: "7155778000",
  iban: "SI56 0201 2026 2090 861",
  swift: "LJBASI2X",
  banka: "NLB d.d.",
  email: "info@rabimbox.si",
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function eur(n: number, cur = "EUR") {
  try { return new Intl.NumberFormat("sl-SI", { style: "currency", currency: cur }).format(n); }
  catch { return n + " " + cur; }
}
// Helvetica (StandardFonts) ne podpira č/š/ž -> pretvorimo v c/s/z
function ascii(s: unknown) {
  return String(s ?? "").normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/đ/g, "d").replace(/Đ/g, "D");
}
function bearer(req: Request): string {
  return (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
}
function b64(bytes: Uint8Array) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
// Prikaz datuma v EU obliki (DD. MM. LLLL) iz ISO zapisa.
function dSi(v: unknown): string {
  if (!v) return "";
  const p = String(v).slice(0, 10).split("-");
  return p.length === 3 ? `${p[2]}. ${p[1]}. ${p[0]}` : String(v);
}

async function makePdf(r: any, kupecNaslov: string, predracun: boolean) {
  const doc = await PDFDocument.create();
  const page = doc.addPage([595.28, 841.89]); // A4
  const { width, height } = page.getSize();

  // Pisava: DejaVu (šumniki), rezerva Helvetica + ascii
  let font: any, bold: any, uni = true;
  try {
    doc.registerFontkit(fontkit);
    const [rb, bb] = await Promise.all([
      fetch("https://cdn.jsdelivr.net/npm/dejavu-fonts-ttf@2.37.3/ttf/DejaVuSans.ttf").then((x) => x.arrayBuffer()),
      fetch("https://cdn.jsdelivr.net/npm/dejavu-fonts-ttf@2.37.3/ttf/DejaVuSans-Bold.ttf").then((x) => x.arrayBuffer()),
    ]);
    font = await doc.embedFont(rb, { subset: true });
    bold = await doc.embedFont(bb, { subset: true });
  } catch (_) {
    uni = false;
    font = await doc.embedFont(StandardFonts.Helvetica);
    bold = await doc.embedFont(StandardFonts.HelveticaBold);
  }
  const X = (t: unknown) => (uni ? String(t ?? "") : ascii(t));

  const M = 50;
  const dark = rgb(0.11, 0.12, 0.14), gray = rgb(0.42, 0.45, 0.5), lineC = rgb(0.85, 0.87, 0.9);
  const T = (t: unknown, x: number, yTop: number, f = font, size = 10, color = dark) =>
    page.drawText(X(t), { x, y: height - yTop, size, font: f, color });
  const R = (t: unknown, xR: number, yTop: number, f = font, size = 10, color = dark) => {
    const s = X(t); const w = f.widthOfTextAtSize(s, size);
    page.drawText(s, { x: xR - w, y: height - yTop, size, font: f, color });
  };
  const HR = (yTop: number, x1 = M, x2 = width - M) =>
    page.drawLine({ start: { x: x1, y: height - yTop }, end: { x: x2, y: height - yTop }, thickness: 0.7, color: lineC });

  const naslov = predracun ? "Predračun" : "Račun";
  const osnova = Number(r.osnova ?? 0), ddv = Number(r.ddv ?? 0), znesek = Number(r.znesek ?? 0);
  const cur = r.valuta || "EUR";

  // Logo desno zgoraj
  try {
    const lb = await fetch(LOGO).then((x) => x.arrayBuffer());
    const img = await doc.embedPng(lb);
    const lw = 46, lh = 46;
    page.drawImage(img, { x: width - M - lw, y: height - M - lh + 4, width: lw, height: lh });
  } catch (_) { /* brez logotipa */ }

  // Naslov
  T(naslov, M, M + 22, bold, 24, dark);

  // Meta (levo pod naslovom)
  let my = M + 48;
  const meta = (l: string, v: unknown) => { T(l, M, my, font, 9, gray); T(v, M + 115, my, font, 9, dark); my += 14; };
  meta("Številka", r.stevilka ?? "");
  meta("Datum izdaje", dSi(r.datum_izdaje));
  meta("Rok plačila", dSi(r.datum_zapadlosti));
  meta("ID za DDV", FIRMA.ddv);

  // Izdajatelj (levo) + Za (desno)
  const colR = 320;
  let cy = M + 122;
  T("Izdajatelj", M, cy, bold, 9, gray);
  T("Za", colR, cy, bold, 9, gray);
  cy += 15;
  const kupecIme = [r.ime, r.priimek].filter(Boolean).join(" ") || "Stranka";
  const headName = r.podjetje ? String(r.podjetje) : kupecIme;
  T(FIRMA.naziv, M, cy, bold, 10.5, dark);
  T(headName, colR, cy, bold, 10.5, dark);
  cy += 14;
  const compLines = [FIRMA.naslov, "TRR: " + FIRMA.iban, FIRMA.banka + " · SWIFT: " + FIRMA.swift, FIRMA.email];
  const custLines = [r.podjetje ? kupecIme : "", kupecNaslov, r.email, r.davcna ? ("ID za DDV: " + String(r.davcna)) : ""].filter(Boolean) as string[];
  const nrows = Math.max(compLines.length, custLines.length);
  for (let i = 0; i < nrows; i++) {
    if (compLines[i]) T(compLines[i], M, cy, font, 9, gray);
    if (custLines[i]) T(custLines[i], colR, cy, font, 9, gray);
    cy += 13;
  }

  // Velik znesek
  let ay = cy + 26;
  T(eur(znesek, cur) + (predracun ? " za plačilo" : " plačano"), M, ay, bold, 17, dark);
  ay += 30;

  // Tabela postavk
  const cQty = 340, cUnit = 432, cTax = 488, cAmt = width - M;
  T("Opis", M, ay, font, 8, gray);
  R("Kol.", cQty, ay, font, 8, gray);
  R("Cena/enoto", cUnit, ay, font, 8, gray);
  R("DDV", cTax, ay, font, 8, gray);
  R("Znesek", cAmt, ay, font, 8, gray);
  ay += 6; HR(ay); ay += 17;
  T(r.opis ?? "Storitev", M, ay, font, 9, dark);
  R("1", cQty, ay, font, 9, dark);
  R(eur(osnova, cur), cUnit, ay, font, 9, dark);
  R("22%", cTax, ay, font, 9, dark);
  R(eur(osnova, cur), cAmt, ay, font, 9, dark);
  ay += 14; HR(ay); ay += 18;

  // Seštevki (desno)
  const totL = 355;
  const totRow = (l: string, v: unknown, b = false) => { const f = b ? bold : font; T(l, totL, ay, f, 10, dark); R(v, cAmt, ay, f, 10, dark); ay += 18; };
  totRow("Osnova (brez DDV)", eur(osnova, cur));
  totRow("DDV – Slovenija (22 %)", eur(ddv, cur));
  ay += 2; HR(ay, totL, cAmt); ay += 16;
  totRow("Skupaj", eur(znesek, cur), true);
  totRow(predracun ? "Za plačilo" : "Plačano", eur(znesek, cur), true);

  // Noga
  const noga = predracun
    ? "Predračun ni davčni dokument. Končni račun prejmete po plačilu."
    : "Račun je izdan v elektronski obliki in velja brez podpisa in žiga.";
  T(noga, M, height - 46, font, 8.5, gray);

  return b64(await doc.save());
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const inp = await req.json();
    if (String(inp.tip || "racun").toLowerCase() !== "racun" || !inp.download) throw new Error("Na voljo je samo prenos plačanega računa.");
    if (!inp.stevilka && !inp.racun_id) throw new Error("Manjka številka računa.");
    const tok = bearer(req);
    if (!tok) throw new Error("Ni dovoljeno.");
    const sb = createClient(SUPABASE_URL, SERVICE_ROLE);
    let query = sb.from("racuni").select("*");
    query = inp.racun_id ? query.eq("id", inp.racun_id) : query.eq("stevilka", inp.stevilka);
    const { data: r, error } = await query.single();
    if (error || !r) throw new Error("Račun ni najden.");
    const { data: paidOrder, error: paidError } = await sb.from("narocila").select("id")
      .eq("stevilka", r.stevilka).eq("placano", true).limit(1).maybeSingle();
    if (paidError || !paidOrder) throw new Error("Račun je na voljo šele po plačilu.");
    const service = !!SERVICE_ROLE && tok === SERVICE_ROLE;
    if (!service) {
      const { data: auth, error: authError } = await sb.auth.getUser(tok);
      if (authError || !auth.user?.email || auth.user.email.toLowerCase() !== String(r.email || "").toLowerCase()) {
        return new Response(JSON.stringify({ error: "Ni dovoljeno." }), { status: 403, headers: { ...cors, "Content-Type": "application/json" } });
      }
    }
    let kupecNaslov = "";
    const { data: kup } = await sb.from("kupci").select("naslov,postna_stevilka,kraj")
      .eq("email", r.email).limit(1).maybeSingle();
    if (kup) kupecNaslov = [kup.naslov, [kup.postna_stevilka, kup.kraj].filter(Boolean).join(" ")].filter(Boolean).join(", ");
    const pdf = await makePdf(r, kupecNaslov, false);
    return new Response(JSON.stringify({ ok: true, pdf, filename: "Racun-" + r.stevilka + ".pdf" }), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message || e) }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
