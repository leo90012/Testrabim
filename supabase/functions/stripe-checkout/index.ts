// Narocilo nastane sele po potrjenem placilu; prej hranimo samo zaseben osnutek.
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const URL = Deno.env.get("SUPABASE_URL") || "";
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") || "";
const PAGE = "https://test.rabimbox.si/narocilo/";
const cors = { "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods":"POST, OPTIONS" };
const response = (v:unknown,status=200) => new Response(JSON.stringify(v),{status,headers:{...cors,"Content-Type":"application/json"}});
const date = (d:Date) => d.toISOString().slice(0,10);
function price(tip:string,n:number):number {
  if(tip==="izposoja") return ({20:69,40:109,60:149,80:189} as Record<number,number>)[n] || 0;
  if(tip==="skladiscenje" && Number.isInteger(n) && n>=1 && n<=50)
    return Math.round(n*(n<=10?4.90:n<=25?4.20:3.80)*100)/100;
  return 0;
}
function clean(raw:any) {
  const tip=String(raw?.tip||""), n=Number(raw?.st_boxov), amount=price(tip,n);
  if(!amount) throw new Error("Neveljavna storitev ali stevilo boxov.");
  const email=String(raw?.email||"").trim().toLowerCase();
  if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error("Neveljaven e-naslov.");
  const datum_dostave=String(raw?.datum_dostave||""),cas_dostave=String(raw?.cas_dostave||"");
  if(!/^\d{4}-\d{2}-\d{2}$/.test(datum_dostave)||!/^\d{2}:\d{2}$/.test(cas_dostave)) throw new Error("Manjka termin.");
  if(!raw?.ime||!raw?.priimek||!raw?.naslov||!raw?.telefon) throw new Error("Manjkajo kontaktni podatki.");
  const order:Record<string,unknown>={tip,st_boxov:n,email,datum_dostave,cas_dostave,
    cena_opis:amount.toFixed(2).replace(".",",")+" €/mesec",
    stopnice:false,krhko:false,pomoc_polnjenje:raw?.pomoc_polnjenje===true};
  for(const f of ["paket","opis_lokacije","naslov","enota","postna_stevilka","mesto","telefon","ime","priimek","podjetje","davcna"])
    order[f]=raw?.[f]?String(raw[f]).slice(0,500):null;
  return {order,amount};
}
async function notify(tip:string,ref:string) {
  const r=await fetch(URL+"/functions/v1/poslji-obvestilo",{method:"POST",
    headers:{Authorization:"Bearer "+KEY,apikey:KEY,"Content-Type":"application/json"},
    body:JSON.stringify({tip,ref})});
  if(!r.ok) throw new Error("E-posta: "+await r.text());
}
async function legacy(sb:ReturnType<typeof createClient>,session:Stripe.Checkout.Session) {
  const ref=session.metadata?.ref;
  if(!ref) throw new Error("Manjka referenca.");
  const {data:o,error}=await sb.from("narocila").select("*").eq("stevilka",ref).maybeSingle();
  if(error||!o||o.status==="preklicano") throw new Error("Starega narocila ni mogoce potrditi.");
  const paid=await sb.from("narocila").update({placano:true}).eq("id",o.id);
  if(paid.error) throw paid.error;
  const total=(session.amount_total||0)/100,base=Math.round(total/1.22*100)/100;
  const {data:inv}=await sb.from("racuni").select("id").eq("stevilka",ref).maybeSingle();
  if(!inv){
    const ir=await sb.from("racuni").insert({stevilka:ref,narocilo_id:o.id,kupec_id:o.kupec_id,
      osnova:base,ddv:Math.round((total-base)*100)/100,znesek:total,valuta:"EUR",
      opis:(o.paket||"Rabimbox")+" - prvi mesec",status:"placan",
      email:o.email,ime:o.ime,priimek:o.priimek,podjetje:o.podjetje,davcna:o.davcna,
      datum_izdaje:date(new Date()),datum_zapadlosti:date(new Date())});
    if(ir.error&&ir.error.code!=="23505") throw ir.error;
  }
  return ref;
}
Deno.serve(async(req)=>{
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  try{
    if(!STRIPE_KEY) throw new Error("Stripe ni nastavljen.");
    const stripe=new Stripe(STRIPE_KEY,{apiVersion:"2023-10-16",httpClient:Stripe.createFetchHttpClient()});
    const sb=createClient(URL,KEY),body=await req.json().catch(()=>({}));
    if(body.confirm&&body.session_id){
      const session=await stripe.checkout.sessions.retrieve(String(body.session_id));
      if(session.payment_status!=="paid") return response({ok:true,paid:false});
      let ref:string;
      if(session.metadata?.draft_id){
        const r=await sb.rpc("rb_finalize_paid_checkout",{p_draft_id:session.metadata.draft_id,
          p_session_id:session.id,p_amount_cents:session.amount_total});
        if(r.error||!r.data?.ref) throw r.error||new Error("Narocila ni bilo mogoce potrditi.");
        ref=r.data.ref;
      }else ref=await legacy(sb,session);
      await notify("lastnik_narocilo",ref);
      await notify("placilo",ref);
      return response({ok:true,paid:true,ref});
    }
    if(!body.order) throw new Error("Manjkajo podatki narocila.");
    const {order,amount}=clean(body.order);
    const occupied=await sb.rpc("zasedeni_termini",{d:order.datum_dostave});
    if(occupied.error) throw occupied.error;
    if((occupied.data||[]).some((s:unknown)=>String(s).slice(0,2)===String(order.cas_dostave).slice(0,2)))
      throw new Error("Izbrani termin je zaseden.");
    const stock=await sb.from("skatle").select("id",{head:true,count:"exact"})
      .eq("status","na_zalogi").is("kupec_id",null);
    if(stock.error) throw stock.error;
    if((stock.count||0)<Number(order.st_boxov)) throw new Error("Trenutno ni dovolj prostih boxov.");
    const ref="RB-"+new Date().getFullYear()+"-"+crypto.randomUUID().slice(0,12).toUpperCase();
    const draft=await sb.from("checkout_osnutki").insert({ref,order_data:order}).select("id").single();
    if(draft.error||!draft.data) throw draft.error||new Error("Osnutka ni bilo mogoce ustvariti.");
    let session:Stripe.Checkout.Session;
    try{
      session=await stripe.checkout.sessions.create({mode:"payment",payment_method_types:["card"],
        allow_promotion_codes:true,customer_email:String(order.email),
        line_items:[{quantity:1,price_data:{currency:"eur",unit_amount:Math.round(amount*100),
          product_data:{name:String(order.paket||"Rabimbox")+" – prvi mesec"}}}],
        metadata:{draft_id:draft.data.id,ref},
        success_url:PAGE+"?placilo=uspeh&ref="+encodeURIComponent(ref)+"&session_id={CHECKOUT_SESSION_ID}",
        cancel_url:PAGE+"?placilo=preklic&ref="+encodeURIComponent(ref)});
    }catch(e){await sb.from("checkout_osnutki").delete().eq("id",draft.data.id);throw e;}
    const link=await sb.from("checkout_osnutki").update({stripe_session_id:session.id}).eq("id",draft.data.id);
    if(link.error) throw link.error;
    return response({url:session.url});
  }catch(e){console.error("Stripe checkout:",e);return response({error:String((e as Error).message||e)},400);}
});
