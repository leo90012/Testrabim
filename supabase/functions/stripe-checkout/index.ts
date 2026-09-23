// Rabimbox – Supabase Edge Function: stripe-checkout
// Ustvari Stripe Checkout sejo (enkratno plačilo prvega meseca) za dano naročilo.
// Znesek se VEDNO izračuna na strežniku iz naročila (ne zaupamo klientu).
//
// Skrivnosti (Supabase -> Project Settings -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY  – tajni ključ iz Stripe (sk_test_... / sk_live_...)
// (SUPABASE_URL in SUPABASE_SERVICE_ROLE_KEY sta na voljo samodejno.)

import Stripe from "https://esm.sh/stripe@14?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const STRIPE_SECRET = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Cenik (mora se ujemati s checkout.js)
function znesekZa(o: any): number {
  const tip = String(o.tip || "").toLowerCase();
  const n = Number(o.st_boxov) || 0;
  if (tip.includes("izpos")) {
    const m: Record<number, number> = { 20: 69, 40: 109, 60: 149, 80: 189 };
    return m[n] ?? 0;
  }
  // skladiščenje: cena/box glede na količino
  const per = n <= 10 ? 4.90 : n <= 25 ? 4.20 : 3.80;
  return Math.round(n * per * 100) / 100;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (!STRIPE_SECRET) throw new Error("STRIPE_SECRET_KEY ni nastavljen (Supabase -> Edge Functions -> Secrets).");
    const stripe = new Stripe(STRIPE_SECRET, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    const body = await req.json().catch(() => ({}));
    const sb = createClient(SUPABASE_URL, SERVICE_ROLE);
    const d = (dt: Date) => dt.toISOString().slice(0, 10);

    // --- Potrditev plačila (service-role -> obide RLS; preveri pri Stripe, da je res plačano) ---
    if (body.confirm && body.session_id) {
      const cs = await stripe.checkout.sessions.retrieve(String(body.session_id));
      const ref0 = cs && cs.metadata ? cs.metadata.ref : null;
      const paid = !!cs && cs.payment_status === "paid";
      if (paid && ref0) {
        const { data: o0 } = await sb.from("narocila").select("*").eq("stevilka", ref0).order("id", { ascending: false }).limit(1).maybeSingle();
        await sb.from("narocila").update({ placano: true }).eq("stevilka", ref0);
        if (o0) {
          const { data: obstoj } = await sb.from("racuni").select("id").eq("stevilka", ref0).limit(1).maybeSingle();
          if (!obstoj) {
            // Dejansko plačani znesek (upošteva kupon/popust); rezerva je izračun iz naročila
            const total = (typeof cs.amount_total === "number" ? cs.amount_total / 100 : znesekZa(o0));
            const osnova = Math.round((total / 1.22) * 100) / 100;
            const ddv = Math.round((total - osnova) * 100) / 100;
            const zap = new Date(); zap.setDate(zap.getDate() + 8);
            let kupec_id: number | null = null;
            try { const { data: k } = await sb.from("kupci").select("id").eq("email", o0.email).limit(1).maybeSingle(); if (k) kupec_id = k.id; } catch (_) { /* ignore */ }
            const { error: invoiceError } = await sb.from("racuni").insert({ stevilka: ref0, narocilo_id: o0.id, kupec_id, osnova, ddv, znesek: total, valuta: "EUR", opis: (o0.paket || "Rabimbox") + " - prvi mesec", status: "placan", email: o0.email, ime: o0.ime, priimek: o0.priimek, podjetje: o0.podjetje, davcna: o0.davcna, datum_izdaje: d(new Date()), datum_zapadlosti: d(zap) });
            if (invoiceError && invoiceError.code !== "23505") throw invoiceError;
          }
          const mail = await fetch(SUPABASE_URL + "/functions/v1/poslji-obvestilo", { method: "POST", headers: { "Authorization": "Bearer " + SERVICE_ROLE, "apikey": SERVICE_ROLE, "Content-Type": "application/json" }, body: JSON.stringify({ tip: "placilo", ref: ref0 }) });
          if (!mail.ok) console.error("Potrditveni e-mail:", await mail.text());
        }
      }
      return new Response(JSON.stringify({ ok: true, paid }), { headers: { ...cors, "Content-Type": "application/json" } });
    }

    // --- Ustvari plačilno sejo ---
    const ref = body.ref, pageUrl = body.pageUrl;
    if (!ref) throw new Error("Manjka ref (številka naročila).");

    const { data: o, error } = await sb.from("narocila").select("*").eq("stevilka", ref).order("id", { ascending: false }).limit(1).maybeSingle();
    if (error || !o) throw new Error("Naročilo ni najdeno.");

    const znesek = znesekZa(o);
    if (znesek <= 0) throw new Error("Neveljaven znesek za to naročilo.");

    const base = String(pageUrl || "").split("?")[0] || "https://rabimbox.si/narocilo/index.html";

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      payment_method_types: ["card"],
      allow_promotion_codes: true,
      customer_email: o.email || undefined,
      line_items: [{
        quantity: 1,
        price_data: {
          currency: "eur",
          unit_amount: Math.round(znesek * 100),
          product_data: { name: (o.paket || "Rabimbox") + " – prvi mesec" },
        },
      }],
      metadata: { ref: String(ref) },
      success_url: base + "?placilo=uspeh&ref=" + encodeURIComponent(String(ref)) + "&session_id={CHECKOUT_SESSION_ID}",
      cancel_url: base + "?placilo=preklic&ref=" + encodeURIComponent(String(ref)),
    });

    return new Response(JSON.stringify({ url: session.url }), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message || e) }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
