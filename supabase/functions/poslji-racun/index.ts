// Rabimbox – Supabase Edge Function: poslji-racun
// Pošlje stranki e-mail z računom ali predračunom (prek Resend) + PDF prilogo (pdf-lib).
//
// Vhod (POST JSON):
//   { stevilka: "RB-...", tip: "racun" | "predracun" }
//   - tip = "racun"      -> prebere zapis iz tabele racuni (po stevilki) -> PDF "RAČUN"
//   - tip = "predracun"  -> prebere naročilo iz narocila (po stevilki), izračuna znesek -> PDF "PREDRAČUN"
//   (privzeto tip = "racun"; podprt je tudi { racun_id } za tip=racun)
//
// Skrivnosti (Supabase -> Project Settings -> Edge Functions -> Secrets):
//   RESEND_API_KEY   – API ključ iz resend.com
//   RACUN_FROM       – npr. "Rabimbox <racuni@rabimbox.si>" (domena potrjena v Resend)
// (SUPABASE_URL in SUPABASE_SERVICE_ROLE_KEY sta na voljo samodejno.)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import fontkit from "https://esm.sh/@pdf-lib/fontkit@1.1.1";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const FROM = Deno.env.get("RACUN_FROM") ?? "Rabimbox <onboarding@resend.dev>";
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
function callerEmail(req: Request): string {
  try {
    const tok = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const p = tok.split(".")[1];
    const j = JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/")));
    return j.email || "";
  } catch (_) { return ""; }
}
function b64(bytes: Uint8Array) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
function d(dt: Date) { return dt.toISOString().slice(0, 10); }
// Prikaz datuma v EU obliki (DD. MM. LLLL) iz ISO zapisa.
function dSi(v: unknown): string {
  if (!v) return "";
  const p = String(v).slice(0, 10).split("-");
  return p.length === 3 ? `${p[2]}. ${p[1]}. ${p[0]}` : String(v);
}

// Cenik (mora se ujemati s checkout.js)
function znesekZa(o: any): number {
  const tip = String(o.tip || "").toLowerCase();
  const n = Number(o.st_boxov) || 0;
  if (tip.includes("izpos")) {
    const m: Record<number, number> = { 20: 49, 40: 89, 60: 119, 80: 149 };
    return m[n] ?? 0;
  }
  const per = n <= 10 ? 3.90 : n <= 25 ? 3.60 : 3.30;
  return Math.round(n * per * 100) / 100;
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
  T(FIRMA.naziv, M, cy, bold, 10.5, dark);
  T(kupecIme, colR, cy, bold, 10.5, dark);
  cy += 14;
  const compLines = [FIRMA.naslov, "TRR: " + FIRMA.iban, FIRMA.banka + " · SWIFT: " + FIRMA.swift, FIRMA.email];
  const custLines = [kupecNaslov, r.email].filter(Boolean) as string[];
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
    const tip = String(inp.tip || "racun").toLowerCase();
    const predracun = tip === "predracun";
    const labelSlo = predracun ? "Predračun" : "Račun";

    const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

    // Pripravi zapis "r" (osnova/ddv/znesek/opis/...) glede na tip
    let r: any = null;
    if (predracun) {
      if (!inp.stevilka) throw new Error("Manjka stevilka narocila");
      const { data: o } = await sb.from("narocila").select("*").eq("stevilka", inp.stevilka).order("id", { ascending: false }).limit(1).maybeSingle();
      if (!o) throw new Error("Naročilo ni najdeno");
      const total = znesekZa(o);
      const osnova = Math.round((total / 1.22) * 100) / 100;
      const ddv = Math.round((total - osnova) * 100) / 100;
      const zap = new Date(); zap.setDate(zap.getDate() + 8);
      r = {
        stevilka: o.stevilka, ime: o.ime, priimek: o.priimek, email: o.email,
        opis: (o.paket || "Rabimbox") + " - prvi mesec", osnova, ddv, znesek: total, valuta: "EUR",
        datum_izdaje: d(new Date()), datum_zapadlosti: d(zap),
      };
    } else {
      if (!inp.racun_id && !inp.stevilka) throw new Error("Manjka racun_id ali stevilka");
      let query = sb.from("racuni").select("*");
      query = inp.racun_id ? query.eq("id", inp.racun_id) : query.eq("stevilka", inp.stevilka);
      const { data, error } = await query.single();
      if (error || !data) throw new Error("Račun ni najden");
      r = data;
    }
    if (!r.email) throw new Error("Manjka e-naslov stranke");

    // Naslov kupca (če obstaja v tabeli kupci)
    let kupecNaslov = "";
    try {
      const { data: kup } = await sb.from("kupci").select("naslov, postna_stevilka, kraj").eq("email", r.email).limit(1).maybeSingle();
      if (kup) kupecNaslov = [kup.naslov, [kup.postna_stevilka, kup.kraj].filter(Boolean).join(" ")].filter(Boolean).join(", ");
    } catch (_) { /* ignore */ }

    const ime = [r.ime, r.priimek].filter(Boolean).join(" ") || "stranka";
    const uvod = predracun
      ? "Hvala za vaše naročilo. V prilogi je predračun v PDF obliki. Po plačilu vam pošljemo končni račun."
      : "Hvala za vaše naročilo. Račun v PDF obliki je priložen temu sporočilu, spodaj pa so ključni podatki:";
    const html = `
      <div style="font-family:Arial,Helvetica,sans-serif;color:#364151;max-width:560px;margin:0 auto">
        <div style="background:#6ec1e4;color:#fff;padding:16px 22px;border-radius:8px 8px 0 0">
          <h2 style="margin:0;font-family:'Lexend',Arial,sans-serif"><img src="${LOGO}" alt="" width="30" height="30" style="vertical-align:middle;margin-right:10px;border-radius:6px" />Rabimbox – ${labelSlo} ${r.stevilka}</h2>
        </div>
        <div style="border:1px solid #e5e8ee;border-top:0;padding:22px;border-radius:0 0 8px 8px">
          <p>Pozdravljeni, ${ime}!</p>
          <p>${uvod}</p>
          <table style="width:100%;border-collapse:collapse;font-size:14px">
            <tr><td style="padding:8px 0;color:#7b8794">Številka</td><td style="text-align:right;font-weight:600">${r.stevilka}</td></tr>
            <tr><td style="padding:8px 0;color:#7b8794">Datum izdaje</td><td style="text-align:right">${dSi(r.datum_izdaje)}</td></tr>
            <tr><td style="padding:8px 0;color:#7b8794">Rok plačila</td><td style="text-align:right">${dSi(r.datum_zapadlosti)}</td></tr>
            <tr><td colspan="2" style="border-top:1px solid #e5e8ee;padding-top:8px"></td></tr>
            <tr><td style="padding:6px 0;color:#7b8794">Osnova</td><td style="text-align:right">${eur(Number(r.osnova), r.valuta)}</td></tr>
            <tr><td style="padding:6px 0;color:#7b8794">DDV (22%)</td><td style="text-align:right">${eur(Number(r.ddv), r.valuta)}</td></tr>
            <tr><td style="padding:10px 0;font-weight:700">Za plačilo</td><td style="text-align:right;font-weight:700;font-size:18px">${eur(Number(r.znesek), r.valuta)}</td></tr>
          </table>
          <p style="color:#7b8794;font-size:12px;margin-top:18px">Za vprašanja smo dosegljivi na info@rabimbox.si. Lep pozdrav, ekipa Rabimbox.</p>
        </div>
      </div>`;

    let pdfB64 = "";
    try { pdfB64 = await makePdf(r, kupecNaslov, predracun); } catch (e) { console.error("PDF napaka:", e); }

    // Način PRENOS: vrni PDF (base64) namesto pošiljanja; le lastnik dokumenta.
    if (inp.download) {
      const ce = callerEmail(req);
      if (!ce || ce.toLowerCase() !== String(r.email || "").toLowerCase()) {
        return new Response(JSON.stringify({ error: "Ni dovoljeno." }), { status: 403, headers: { ...cors, "Content-Type": "application/json" } });
      }
      if (!pdfB64) throw new Error("PDF ni bil ustvarjen.");
      const fname = (predracun ? "Predracun-" : "Racun-") + r.stevilka + ".pdf";
      return new Response(JSON.stringify({ ok: true, pdf: pdfB64, filename: fname }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    const fname = (predracun ? "Predracun-" : "Racun-") + r.stevilka + ".pdf";
    const body: Record<string, unknown> = {
      from: FROM, to: [r.email], subject: `${labelSlo} ${r.stevilka} – Rabimbox`, html,
    };
    if (pdfB64) body.attachments = [{ filename: fname, content: pdfB64 }];

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error("Resend napaka: " + (await res.text()));

    // Le pri pravem računu posodobimo status v tabeli racuni
    if (!predracun && r.id) { try { await sb.from("racuni").update({ status: "poslan" }).eq("id", r.id); } catch (_) { /* ignore */ } }

    return new Response(JSON.stringify({ ok: true, tip, pdf: !!pdfB64 }), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message || e) }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
