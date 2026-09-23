// Rabimbox – Supabase Edge Function: poslji-obvestilo
// Pošlje potrditve plačila in obvestila o dostavi/prevzemu prek Resend.
//
// Skrivnosti (Supabase -> Project Settings -> Edge Functions -> Secrets):
//   RESEND_API_KEY   – API ključ iz resend.com
// (SUPABASE_URL in SUPABASE_SERVICE_ROLE_KEY sta na voljo samodejno.)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const FROM = "Rabimbox <narocila@rabimbox.si>";
const PANEL_URL = "https://test.rabimbox.si/moj-profil/";
const WAREHOUSE_URL = "https://skladisce.rabimbox.si/";
const REVIEW_URL = "https://www.google.com/search?q=Rabimbox+skladi%C5%A1%C4%8Denje+na+zahtevo";
const OWNER_EMAIL = Deno.env.get("OWNER_EMAIL") ?? "info@rabimbox.si";

function isService(req: Request): boolean {
  const tok = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  return !!SERVICE_ROLE && tok === SERVICE_ROLE;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function esc(s: unknown): string {
  return String(s ?? "").replace(/[&<>"]/g, (m) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[m] as string));
}
function fmtDate(d: unknown): string {
  if (!d) return "-";
  const dt = new Date(String(d));
  if (isNaN(dt.getTime())) return esc(d);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(dt.getDate())}. ${p(dt.getMonth() + 1)}. ${dt.getFullYear()}`;
}
function eur(v: unknown): string {
  const n = Number(v);
  if (!isFinite(n)) return "-";
  return n.toFixed(2).replace(".", ",") + " €";
}

// Preprosta blagovna predloga e-pošte
function ovoj(naslov: string, telo: string): string {
  return `<div style="background:#f4f6f9;padding:24px 0;font-family:Arial,Helvetica,sans-serif;color:#2a3342">
    <div style="max-width:560px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 6px 22px rgba(16,24,40,.06)">
      <div style="background:#6ec1e4;padding:16px 26px;color:#fff;font-size:20px;font-weight:700;letter-spacing:.5px"><img src="https://rabimbox.si/wp-content/uploads/2024/08/cropped-3-270x270.png" alt="" width="34" height="34" style="vertical-align:middle;margin-right:10px;border-radius:6px" />Rabimbox</div>
      <div style="padding:26px">
        <h1 style="font-size:20px;margin:0 0 14px;color:#111">${esc(naslov)}</h1>
        ${telo}
      </div>
      <div style="padding:16px 26px;border-top:1px solid #eef1f6;color:#7b8794;font-size:12px">
        Rabimbox · <a href="mailto:info@rabimbox.si" style="color:#6ec1e4;text-decoration:none">info@rabimbox.si</a> · +386 (0)40 796 040
      </div>
    </div>
  </div>`;
}
function vrstica(k: string, v: string): string {
  return `<tr><td style="padding:6px 0;color:#7b8794;font-size:13px">${esc(k)}</td><td style="padding:6px 0;text-align:right;color:#2a3342;font-size:14px;font-weight:600">${esc(v)}</td></tr>`;
}
function btn(href: string, label: string): string {
  return `<div style="margin:22px 0 6px"><a href="${esc(href)}" style="display:inline-block;background:#6ec1e4;color:#fff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:8px;font-size:14px">${esc(label)}</a></div>`;
}

async function posljiEmail(to: string, subject: string, html: string, attachments: Array<{filename:string;content:string}> = []) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html, ...(attachments.length ? { attachments } : {}) }),
  });
  if (!res.ok) throw new Error("Resend napaka: " + (await res.text()));
  return await res.json();
}
async function claimEmail(sb: ReturnType<typeof createClient>, tip: string, vir: string, virId: number, datum: string) {
  const { error } = await sb.from("email_obvestila").insert({ tip, vir, vir_id: virId, datum });
  if (error && error.code === "23505") return false;
  if (error) throw error;
  return true;
}
async function releaseEmail(sb: ReturnType<typeof createClient>, tip: string, vir: string, virId: number, datum: string) {
  await sb.from("email_obvestila").delete().match({ tip, vir, vir_id: virId, datum });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (!RESEND_API_KEY) throw new Error("RESEND_API_KEY ni nastavljen.");
    const body = await req.json().catch(() => ({}));
    const tip = String(body.tip || "");
    const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

    if (tip === "placilo") {
      if (!isService(req)) throw new Error("Ni dovoljeno.");
      const ref = body.ref;
      if (!ref) throw new Error("Manjka ref.");
      const { data: o } = await sb.from("narocila").select("*").eq("stevilka", ref).order("id", { ascending: false }).limit(1).maybeSingle();
      if (!o || !o.email) throw new Error("Naročilo ali e-naslov ni najden.");
      if (o.placano !== true) throw new Error("Plačilo še ni potrjeno.");
      const { data: racun, error: racunError } = await sb.from("racuni").select("id,status,stevilka").eq("stevilka", ref).limit(1).maybeSingle();
      if (racunError || !racun) throw new Error("Plačani račun še ni pripravljen.");
      if (racun.status === "poslan" || racun.status === "posiljanje") return new Response(JSON.stringify({ ok: true, preskoceno: "potrditev je že poslana ali v obdelavi" }), { headers: { ...cors, "Content-Type": "application/json" } });
      const { data: claim, error: claimError } = await sb.from("racuni").update({ status: "posiljanje" }).eq("id", racun.id).eq("status", racun.status).select("id").maybeSingle();
      if (claimError || !claim) return new Response(JSON.stringify({ ok: true, preskoceno: "potrditev že obdeluje drug klic" }), { headers: { ...cors, "Content-Type": "application/json" } });
      try {
        const pdfRes = await fetch(SUPABASE_URL + "/functions/v1/poslji-racun", { method: "POST", headers: { "Authorization": "Bearer " + SERVICE_ROLE, "apikey": SERVICE_ROLE, "Content-Type": "application/json" }, body: JSON.stringify({ stevilka: ref, download: true }) });
        const pdf = await pdfRes.json();
        if (!pdfRes.ok || !pdf.pdf) throw new Error("Računa ni bilo mogoče pripraviti.");
        const ime = o.ime ? ` ${esc(o.ime)}` : "";
      const tabela = `<table style="width:100%;border-collapse:collapse;margin-top:6px">
        ${vrstica("Številka naročila", o.stevilka || ("#" + o.id))}
        ${vrstica("Storitev", String(o.tip || "").toLowerCase().includes("izpos") ? "Izposoja" : "Skladiščenje")}
        ${vrstica("Paket", o.paket || "-")}
        ${o.cena_opis ? vrstica("Cena", o.cena_opis) : ""}
        ${o.datum_dostave ? vrstica("Termin dostave", fmtDate(o.datum_dostave) + (o.cas_dostave ? " ob " + o.cas_dostave : "")) : ""}
        ${o.naslov ? vrstica("Naslov", o.naslov + (o.mesto ? ", " + o.mesto : "")) : ""}
      </table>`;

        const telo = `<p style="font-size:14px;line-height:1.6;margin:0 0 4px">Pozdravljeni${ime}, zahvaljujemo se vam za vaše naročilo.</p>
          ${tabela}
          <p style="font-size:13.5px;color:#7b8794;line-height:1.6;margin:16px 0 0">Račun se nahaja v priponki.</p>
          ${btn(PANEL_URL, "Moj račun")}`;
        await posljiEmail(o.email, "Naročilo je potrjeno – Rabimbox", ovoj("Naročilo je potrjeno", telo), [{ filename: pdf.filename || `Racun-${ref}.pdf`, content: pdf.pdf }]);
        await sb.from("racuni").update({ status: "poslan" }).eq("id", racun.id);
        return new Response(JSON.stringify({ ok: true, sent: "placilo" }), { headers: { ...cors, "Content-Type": "application/json" } });
      } catch (e) {
        await sb.from("racuni").update({ status: racun.status }).eq("id", racun.id).eq("status", "posiljanje");
        throw e;
      }
    }

    if (tip === "povprasevanje") {
      const to = body.email;
      if (!to) throw new Error("Manjka email za povpraševanje.");
      // Proti zlorabi: pošljemo samo, če je bilo v zadnjih 15 min res oddano povpraševanje s tem e-naslovom.
      const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
      const { data: pv } = await sb.from("povprasevanja").select("id").ilike("email", to).gt("created_at", since).limit(1).maybeSingle();
      if (!pv) throw new Error("Ni veljavne oddaje povpraševanja.");
      const ime = body.ime ? `, ${esc(body.ime)}` : "";
      const tabela = `<table style="width:100%;border-collapse:collapse;margin-top:6px">
        ${(body.ime || body.priimek) ? vrstica("Ime in priimek", [body.ime, body.priimek].filter(Boolean).join(" ")) : ""}
        ${body.email ? vrstica("E-pošta", String(body.email)) : ""}
        ${body.telefon ? vrstica("Telefon", String(body.telefon)) : ""}
        ${body.paket ? vrstica("Paket", String(body.paket)) : ""}
      </table>`;
      const vpr = body.vprasanje ? `<div style="margin-top:14px"><div style="color:#7b8794;font-size:13px;margin-bottom:4px">Vaše sporočilo:</div><div style="background:#f4f6f9;border-radius:8px;padding:12px 14px;font-size:14px;line-height:1.6;color:#2a3342">${esc(body.vprasanje)}</div></div>` : "";
      const telo = `<p style="font-size:14px;line-height:1.6;margin:0 0 4px">Pozdravljeni${ime}, hvala za vaše povpraševanje! Prejeli smo ga in vas bomo kontaktirali v najkrajšem možnem času.</p>
        ${tabela}${vpr}
        ${btn(PANEL_URL, "Moj račun")}`;
      await posljiEmail(to, "Povzetek vašega povpraševanja – Rabimbox", ovoj("Povpraševanje je prejeto", telo));
      return new Response(JSON.stringify({ ok: true, sent: "povprasevanje" }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    // Paketni opomnik: pošlje vsem naročninam, ki se iztečejo čez N dni (privzeto 5).
    if (tip === "obnova_batch") {
      if (!isService(req)) throw new Error("Ni dovoljeno.");
      const dni = Number(body.dni) || 5;
      const cilj = new Date(); cilj.setDate(cilj.getDate() + dni);
      const ciljStr = cilj.toISOString().slice(0, 10);
      const { data: subs } = await sb.from("narocnine").select("id, kupec_id, tip, datum_do, status").eq("status", "aktivna").eq("datum_do", ciljStr);
      let poslano = 0;
      for (const su of (subs || [])) {
        try {
          const { data: k } = await sb.from("kupci").select("email, ime").eq("id", su.kupec_id).limit(1).maybeSingle();
          if (!k || !k.email) continue;
          const ime = k.ime ? `, ${esc(k.ime)}` : "";
          const telo = `<p style="font-size:14px;line-height:1.6;margin:0 0 10px">Pozdravljeni${ime}, vaša naročnina se izteče <b>${fmtDate(su.datum_do)}</b>.</p>
            <p style="font-size:13.5px;color:#7b8794;line-height:1.6;margin:0">Za podaljšanje ali spremembo naročnine obiščite svoj račun ali nas kontaktirajte.</p>
            ${btn(PANEL_URL, "Upravljaj naročnino")}`;
          await posljiEmail(k.email, "Opomnik: obnova naročnine – Rabimbox", ovoj("Vaša naročnina se kmalu izteče", telo));
          poslano++;
        } catch (_) { /* ignore posamezno */ }
      }
      return new Response(JSON.stringify({ ok: true, sent: "obnova_batch", poslano }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    // Obvestilo LASTNIKU o novem naročilu (fiksni naslov)
    if (tip === "lastnik_narocilo") {
      if (!isService(req)) throw new Error("Ni dovoljeno.");
      const ref = body.ref;
      if (!ref) throw new Error("Manjka ref.");
      const { data: o } = await sb.from("narocila").select("*").eq("stevilka", ref).order("id", { ascending: false }).limit(1).maybeSingle();
      if (!o || o.placano !== true) throw new Error("Plačano naročilo ni najdeno.");
      const dan = "2000-01-01";
      if (!(await claimEmail(sb, "lastnik_narocilo", "narocilo", o.id, dan))) {
        return new Response(JSON.stringify({ ok: true, preskoceno: "že poslano" }), { headers: { ...cors, "Content-Type": "application/json" } });
      }
      try {
      const tabela = `<table style="width:100%;border-collapse:collapse;margin-top:6px">
        ${vrstica("Številka", o.stevilka || ("#" + o.id))}
        ${vrstica("Storitev", String(o.tip || "").toLowerCase().includes("izpos") ? "Izposoja" : "Skladiščenje")}
        ${vrstica("Paket", o.paket || "-")}
        ${o.cena_opis ? vrstica("Cena", o.cena_opis) : ""}
        ${vrstica("Kupec", [o.ime, o.priimek].filter(Boolean).join(" ") || "-")}
        ${o.email ? vrstica("E-pošta", o.email) : ""}
        ${o.telefon ? vrstica("Telefon", o.telefon) : ""}
        ${o.datum_dostave ? vrstica("Termin", fmtDate(o.datum_dostave) + (o.cas_dostave ? " ob " + o.cas_dostave : "")) : ""}
        ${o.naslov ? vrstica("Naslov", o.naslov + (o.mesto ? ", " + o.mesto : "")) : ""}
        ${o.opis_lokacije ? vrstica("Objekt", o.opis_lokacije) : ""}
        ${vrstica("Plačano", o.placano === true ? "Da" : "Ne")}
      </table>`;
      const telo = `<p style="font-size:14px;margin:0 0 4px">Novo naročilo na spletni strani:</p>${tabela}${btn(WAREHOUSE_URL, "Odpri panel")}`;
      await posljiEmail(OWNER_EMAIL, `Novo naročilo ${o.stevilka || ""} – Rabimbox`, ovoj("Novo naročilo", telo));
      return new Response(JSON.stringify({ ok: true, sent: "lastnik_narocilo" }), { headers: { ...cors, "Content-Type": "application/json" } });
      } catch (mailError) {
        await releaseEmail(sb, "lastnik_narocilo", "narocilo", o.id, dan);
        throw mailError;
      }
    }

    // Obvestilo LASTNIKU o povpraševanju (fiksni naslov)
    if (tip === "lastnik_povprasevanje") {
      const tabela = `<table style="width:100%;border-collapse:collapse;margin-top:6px">
        ${vrstica("Ime in priimek", [body.ime, body.priimek].filter(Boolean).join(" ") || "-")}
        ${body.email ? vrstica("E-pošta", String(body.email)) : ""}
        ${body.telefon ? vrstica("Telefon", String(body.telefon)) : ""}
        ${body.paket ? vrstica("Paket", String(body.paket)) : ""}
      </table>`;
      const vpr = body.vprasanje ? `<div style="margin-top:12px;background:#f4f6f9;border-radius:8px;padding:12px 14px;font-size:14px;line-height:1.6;color:#2a3342">${esc(body.vprasanje)}</div>` : "";
      const telo = `<p style="font-size:14px;margin:0 0 4px">Novo povpraševanje s spletne strani:</p>${tabela}${vpr}`;
      await posljiEmail(OWNER_EMAIL, "Novo povpraševanje – Rabimbox", ovoj("Novo povpraševanje", telo));
      return new Response(JSON.stringify({ ok: true, sent: "lastnik_povprasevanje" }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    // Obvestilo STRANKI ob dostavi/prevzemu (samo service_role -> DB trigger)
    if (tip === "dostava" || tip === "prevzem") {
      if (!isService(req)) throw new Error("Ni dovoljeno.");
      const to = body.email;
      if (!to) throw new Error("Manjka email.");
      const ime = body.ime ? ` ${esc(body.ime)}` : "";
      const jeDost = tip === "dostava";
      const vrnitev = jeDost && body.faza === "vrnitev";
      const naslovE = vrnitev ? "Vaši boxi so ponovno pri vas" : jeDost ? "Boxi so pri vas" : "Boxi so prevzeti v skladišče";
      const stevilo = Number(body.st_boksov) > 0 ? ` (${Number(body.st_boksov)} boxov)` : "";
      const besedilo = vrnitev
        ? "vaše boxe smo vam ponovno dostavili. Hvala, ker uporabljate Rabimbox."
        : jeDost ? "vaše boxe smo dostavili na dogovorjeni naslov. Zdaj so pri vas."
        : "vaše boxe smo prevzeli in jih shranili v naše skladišče.";
      const telo = `<p style="font-size:14px;line-height:1.6;margin:0 0 6px">Pozdravljeni${ime}, ${besedilo}</p>
        <p style="font-size:13.5px;color:#7b8794;line-height:1.6;margin:0">Stanje${stevilo} lahko spremljate v Mojem računu.</p>
        ${btn(PANEL_URL, "Moj račun")}`;
      await posljiEmail(to, naslovE + " – Rabimbox", ovoj(naslovE, telo));
      return new Response(JSON.stringify({ ok: true, sent: tip }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    if (tip === "dostava_opomnik_batch") {
      if (!isService(req)) throw new Error("Ni dovoljeno.");
      const jutri = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Ljubljana", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(Date.now() + 86400000));
      let poslano = 0;
      const { data: orders, error: ordersError } = await sb.from("narocila").select("id,ime,email,stevilka,datum_dostave,cas_dostave,naslov,postna_stevilka,mesto,status,placano").eq("datum_dostave", jutri).eq("placano", true).in("status", ["nova", "caka_dostavo"]);
      if (ordersError) throw ordersError;
      const pojutrisnjem = new Date(jutri + "T00:00:00Z");
      pojutrisnjem.setUTCDate(pojutrisnjem.getUTCDate() + 1);
      const { data: requests, error: requestsError } = await sb.from("zahteve_dostave").select("id,kupec_id,datum_dostave,opomba,status")
        .gte("datum_dostave", jutri + "T00:00:00Z")
        .lt("datum_dostave", pojutrisnjem.toISOString())
        .in("status", ["nova", "caka_dostavo"]);
      if (requestsError) throw requestsError;
      const entries: Array<{vir:string;id:number;email:string;ime:string;vrsta:string;datum:string;ura:string;naslov:string}> = [];
      for (const o of orders || []) if (o.email) entries.push({ vir: "narocilo", id: o.id, email: o.email, ime: o.ime || "", vrsta: "dostavo", datum: jutri, ura: o.cas_dostave || "", naslov: [o.naslov, o.postna_stevilka, o.mesto].filter(Boolean).join(", ") });
      for (const z of requests || []) {
        const { data: k } = await sb.from("kupci").select("email,ime").eq("id", z.kupec_id).limit(1).maybeSingle();
        if (!k?.email) continue;
        const details = String(z.opomba || "");
        const vrsta = details.split(" - ")[0] || "prevoz";
        const naslov = /Naslov:\s*([^|]+)/i.exec(details)?.[1]?.trim() || "";
        const ura = /Ura:\s*([^|]+)/i.exec(details)?.[1]?.trim() || "";
        entries.push({ vir: "zahteva", id: z.id, email: k.email, ime: k.ime || "", vrsta, datum: jutri, ura, naslov });
      }
      for (const e of entries) {
        if (!(await claimEmail(sb, "opomnik_dostave", e.vir, e.id, e.datum))) continue;
        try {
          const telo = `<p style="font-size:14px;line-height:1.6">Pozdravljeni${e.ime ? " " + esc(e.ime) : ""},</p>
            <p style="font-size:14px;line-height:1.6">spominjamo vas, da je vaš ${esc(e.vrsta)} predviden jutri.</p>
            <table style="width:100%">${vrstica("Datum", fmtDate(e.datum))}${e.ura ? vrstica("Ura", e.ura) : ""}${e.naslov ? vrstica("Naslov", e.naslov) : ""}</table>
            <p style="font-size:13.5px;line-height:1.6">Če želite sporočiti spremembo, nas kontaktirajte na info@rabimbox.si.</p>${btn(PANEL_URL, "Moj račun")}`;
          await posljiEmail(e.email, "Opomnik za jutrišnji prevoz – Rabimbox", ovoj("Jutri smo pri vas", telo));
          poslano++;
        } catch (err) { await releaseEmail(sb, "opomnik_dostave", e.vir, e.id, e.datum); console.error("Opomnik dostave:", err); }
      }
      return new Response(JSON.stringify({ ok: true, sent: "dostava_opomnik_batch", poslano }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    if (tip === "zakljucek") {
      if (!isService(req)) {
        const tok = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
        const { data: auth } = await sb.auth.getUser(tok);
        if (!auth.user) throw new Error("Ni dovoljeno.");
        const { data: staff } = await sb.from("osebje").select("user_id").eq("user_id", auth.user.id).limit(1).maybeSingle();
        if (!staff) throw new Error("Ni dovoljeno.");
      }
      const id = Number(body.narocilo_id);
      if (!Number.isInteger(id) || id < 1) throw new Error("Manjka narocilo_id.");
      const { data: o } = await sb.from("narocila").select("id,ime,email,status").eq("id", id).limit(1).maybeSingle();
      if (!o || !o.email || o.status !== "zakljuceno") throw new Error("Naročilo še ni zaključeno.");
      const datum = "1970-01-01";
      if (!(await claimEmail(sb, "zakljucek", "narocilo", id, datum))) return new Response(JSON.stringify({ ok: true, preskoceno: "zahvala je že poslana" }), { headers: { ...cors, "Content-Type": "application/json" } });
      try {
        const telo = `<p style="font-size:14px;line-height:1.6">Pozdravljeni${o.ime ? " " + esc(o.ime) : ""},</p>
          <p style="font-size:14px;line-height:1.6">zahvaljujemo se vam za zaupanje. Vaše naročilo je zaključeno.</p>
          <p style="font-size:14px;line-height:1.6">Veseli bomo vaše ocene na Googlu.</p>
          ${btn(REVIEW_URL, "Oddajte Google oceno")}`;
        await posljiEmail(o.email, "Hvala za zaupanje – Rabimbox", ovoj("Hvala za vaše naročilo", telo));
      } catch (err) { await releaseEmail(sb, "zakljucek", "narocilo", id, datum); throw err; }
      return new Response(JSON.stringify({ ok: true, sent: "zakljucek" }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    throw new Error("Neznan tip obvestila.");
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message || e) }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
