// Rabimbox – Supabase Edge Function: stripe-webhook
// Stripe pokliče to funkcijo ob dogodku plačila. Ob 'checkout.session.completed':
//   1) naročilo označi kot plačano (narocila.placano = true, status = 'placano'),
//   2) ustvari račun (racuni) z osnovo + 22% DDV,
//   3) sproži pošiljanje računa po e-pošti (funkcija poslji-racun).
//
// Skrivnosti (Supabase -> Project Settings -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY      – sk_test_... / sk_live_...
//   STRIPE_WEBHOOK_SECRET  – whsec_... (iz Stripe Dashboard -> Webhooks)
// (SUPABASE_URL in SUPABASE_SERVICE_ROLE_KEY sta na voljo samodejno.)
//
// POMEMBNO: to funkcijo objavi z --no-verify-jwt (Stripe ne pošilja Supabase JWT).

import Stripe from "https://esm.sh/stripe@14?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const STRIPE_SECRET = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const WH_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function stripeClient() {
  return new Stripe(STRIPE_SECRET, {
    apiVersion: "2023-10-16",
    httpClient: Stripe.createFetchHttpClient(),
  });
}

function znesekZa(o: any): number {
  const tip = String(o.tip || "").toLowerCase();
  const n = Number(o.st_boxov) || 0;
  if (tip.includes("izpos")) {
    const m: Record<number, number> = { 20: 69, 40: 109, 60: 149, 80: 189 };
    return m[n] ?? 0;
  }
  const per = n <= 10 ? 4.90 : n <= 25 ? 4.20 : 3.80;
  return Math.round(n * per * 100) / 100;
}
function d(dt: Date) { return dt.toISOString().slice(0, 10); }

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  const body = await req.text();
  let event: any;
  try {
    event = await stripeClient().webhooks.constructEventAsync(body, sig!, WH_SECRET);
  } catch (e) {
    return new Response("Napačen podpis: " + String((e as Error).message || e), { status: 400 });
  }

  try {
    if (event.type === "checkout.session.completed") {
      const session = event.data.object;
      const ref = session?.metadata?.ref;
      if (ref) {
        const sb = createClient(SUPABASE_URL, SERVICE_ROLE);
        const { data: o } = await sb.from("narocila").select("*").eq("stevilka", ref).order("id", { ascending: false }).limit(1).maybeSingle();

        // 1) označi plačano
        await sb.from("narocila").update({ placano: true, status: "placano" }).eq("stevilka", ref);

        if (o) {
          // 2) ustvari račun (če še ne obstaja)
          const { data: obstoj } = await sb.from("racuni").select("id").eq("stevilka", ref).limit(1).maybeSingle();
          if (!obstoj) {
            const total = znesekZa(o);
            const osnova = Math.round((total / 1.22) * 100) / 100;
            const ddv = Math.round((total - osnova) * 100) / 100;
            const zap = new Date(); zap.setDate(zap.getDate() + 8);
            // poišči kupca po e-pošti
            let kupec_id: number | null = null;
            try { const { data: k } = await sb.from("kupci").select("id").eq("email", o.email).limit(1).maybeSingle(); if (k) kupec_id = k.id; } catch (_) { /* ignore */ }
            await sb.from("racuni").insert({
              stevilka: ref, kupec_id, osnova, ddv, znesek: total, valuta: "EUR",
              opis: (o.paket || "Rabimbox") + " - prvi mesec", status: "placan",
              email: o.email, ime: o.ime, priimek: o.priimek, podjetje: o.podjetje, davcna: o.davcna,
              datum_izdaje: d(new Date()), datum_zapadlosti: d(zap),
            });
            // 3) pošlji račun po e-pošti (funkcija poslji-racun)
            try {
              await fetch(SUPABASE_URL + "/functions/v1/poslji-racun", {
                method: "POST",
                headers: { "Authorization": "Bearer " + SERVICE_ROLE, "apikey": SERVICE_ROLE, "Content-Type": "application/json" },
                body: JSON.stringify({ stevilka: ref }),
              });
            } catch (_) { /* e-mail ni ključen za potrditev plačila */ }
          }
        }
      }
    }
    return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    // Vrni 200, da Stripe ne ponavlja v nedogled zaradi naše napake pri obdelavi
    console.error("Webhook obdelava napaka:", e);
    return new Response(JSON.stringify({ received: true, warn: String((e as Error).message || e) }), { headers: { "Content-Type": "application/json" } });
  }
});
