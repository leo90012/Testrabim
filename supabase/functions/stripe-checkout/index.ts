// Narocilo nastane sele po potrjenem placilu; prej hranimo samo zaseben osnutek.
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {validateOrder,invoiceDescription,addDays,TERMS_VERSION,renewalPrice,text} from "../_shared/billing-rules.ts";
const URL = Deno.env.get("SUPABASE_URL") || "";
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") || "";
const PAGE = "https://test.rabimbox.si/narocilo/";
const PANEL = "https://test.rabimbox.si/moj-profil/";
const cors = { "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods":"POST, OPTIONS" };
const response = (v:unknown,status=200) => new Response(JSON.stringify(v),{status,headers:{...cors,"Content-Type":"application/json"}});
const date = (d:Date) => d.toISOString().slice(0,10);
function price(tip:string,n:number){return renewalPrice(tip,n);}
async function invoiceSetup(client:Stripe,o:any,key:string){
  const description=invoiceDescription(o.tip,o.st_boxov,String(o.datum_dostave).slice(0,10),addDays(String(o.datum_dostave).slice(0,10),30));
  const customer=await client.customers.create({preferred_locales:["sl"],email:o.email,name:o.podjetje||[o.ime,o.priimek].filter(Boolean).join(" "),phone:o.telefon,
    address:{line1:o.naslov,line2:o.enota||undefined,postal_code:o.postna_stevilka,city:o.mesto,country:"SI"},metadata:{rabimbox_ref:key}},{idempotencyKey:"rb-customer-"+key});
  const taxes=await client.taxRates.list({active:true,limit:100});
  const vat=taxes.data.find((t:Stripe.TaxRate)=>t.inclusive&&t.percentage===22&&t.country==="SI")||await client.taxRates.create({display_name:"DDV",percentage:22,inclusive:true,country:"SI"},{idempotencyKey:"rabimbox-vat-si-22-inclusive"});
  return {customer:customer.id,description,vat:vat.id};
}
async function notify(tip:string,ref:string) {
  const r=await fetch(URL+"/functions/v1/poslji-obvestilo",{method:"POST",
    headers:{Authorization:"Bearer "+KEY,apikey:KEY,"Content-Type":"application/json"},
    body:JSON.stringify({tip,ref})});
  if(!r.ok) throw new Error("E-posta: "+await r.text());
}
async function legacy(sb:any,session:Stripe.Checkout.Session) {
  const ref=session.metadata?.ref;
  if(!ref) throw new Error("Manjka referenca.");
  const {data:o,error}=await sb.from("narocila").select("*").eq("stevilka",ref).maybeSingle();
  if(error||!o||o.status==="preklicano") throw new Error("Starega narocila ni mogoce potrditi.");
  const paid=await sb.from("narocila").update({placano:true}).eq("id",o.id);
  if(paid.error) throw paid.error;
  const total=(session.amount_total||0)/100,base=Math.round(total/1.22*100)/100;
  const {data:inv}=await sb.from("racuni").select("id,status").eq("narocilo_id",o.id).order("id").limit(1).maybeSingle();
  if(inv&&inv.status!=="placan"){
    const up=await sb.from("racuni").update({status:"placan"}).eq("id",inv.id);
    if(up.error) throw up.error;
  }
  if(!inv){
    const ir=await sb.from("racuni").insert({stevilka:ref,narocilo_id:o.id,kupec_id:o.kupec_id,
      osnova:base,ddv:Math.round((total-base)*100)/100,znesek:total,valuta:"EUR",
      opis:invoiceDescription(o.tip,o.st_boxov,String(o.datum_dostave).slice(0,10),addDays(String(o.datum_dostave).slice(0,10),30)),status:"placan",placano:true,obdobje_od:o.datum_dostave,obdobje_do:addDays(String(o.datum_dostave).slice(0,10),30),
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
      if(session.mode==="setup"){
        const r=await fetch(URL+"/functions/v1/rb-billing",{method:"POST",headers:{Authorization:"Bearer "+KEY,apikey:KEY,"Content-Type":"application/json"},body:JSON.stringify({action:"checkout_completed",session_id:session.id,test:!session.livemode})});
        if(!r.ok)throw new Error(await r.text());return response({ok:true,paid:false,card_saved:true});
      }
      if(session.payment_status!=="paid") return response({ok:true,paid:false});
      let ref:string;
      if(session.metadata?.draft_id){
        const r=await sb.rpc("rb_finalize_paid_checkout",{p_draft_id:session.metadata.draft_id,
          p_session_id:session.id,p_amount_cents:session.amount_total});
        if(r.error||!r.data?.ref) throw r.error||new Error("Narocila ni bilo mogoce potrditi.");
        ref=r.data.ref;
      }else ref=await legacy(sb,session);
      if(session.metadata?.auto_renew==="30d"){
        const r=await fetch(URL+"/functions/v1/rb-billing",{method:"POST",headers:{Authorization:"Bearer "+KEY,apikey:KEY,"Content-Type":"application/json"},body:JSON.stringify({action:"checkout_completed",session_id:session.id,test:!session.livemode})});
        if(!r.ok)throw new Error("Povezava naročnine še ni dokončana. "+await r.text());
      }
      await notify("lastnik_narocilo",ref);
      await notify("placilo",ref);
      return response({ok:true,paid:true,ref});
    }
    // Placilo obstojecega neplacanega narocila (npr. rocni vnos) iz panela "Moj profil".
    // Potrditev po placilu gre skozi obstojeco pot confirm -> legacy (metadata.ref).
    if(body.ref&&!body.order){
      if(body.auto_renew_consent!==true||body.terms_version!==TERMS_VERSION)throw new Error("Potrdite samodejno podaljšanje vsakih 30 dni.");
      const token=(req.headers.get("authorization")||"").replace(/^Bearer\s+/i,"");
      const auth=token?await sb.auth.getUser(token):null;
      const user=auth?.data?.user;
      if(!user?.email) return response({error:"Za plačilo se prijavi v Moj profil."},401);
      const {data:o,error}=await sb.from("narocila")
        .select("*")
        .eq("stevilka",String(body.ref)).maybeSingle();
      if(error) throw error;
      // Placa lahko samo lastnik narocila (isti e-naslov kot prijava).
      if(!o||String(o.email||"").trim().toLowerCase()!==user.email.trim().toLowerCase())
        throw new Error("Naročila ni mogoče najti.");
      if(o.placano===true) throw new Error("Naročilo je že plačano.");
      if(String(o.status||"").toLowerCase().includes("preklic")) throw new Error("Naročilo je preklicano.");
      const amount=price(String(o.tip||""),Number(o.st_boxov));
      if(!amount) throw new Error("Zneska za to naročilo ni mogoče izračunati. Kontaktirajte nas.");
      const ref=String(o.stevilka);
      const {data:manualSub}=await sb.from("narocnine").select("datum_do").eq("narocilo_id",o.id).limit(1).maybeSingle();
      if(manualSub?.datum_do&&manualSub.datum_do<=date(new Date()))throw new Error("Obdobje naročila je že poteklo. Kontaktirajte nas.");
      const details=await invoiceSetup(stripe,o,ref);
      const session=await stripe.checkout.sessions.create({locale:"sl",mode:"payment",payment_method_types:["card"],customer:details.customer,payment_intent_data:{setup_future_usage:"off_session"},invoice_creation:{enabled:true,invoice_data:{description:details.description,footer:"Rabim d.o.o. · info@rabimbox.si",...(o.davcna?{custom_fields:[{name:"Davčna številka",value:text(o.davcna,100,true)}]}:{})}},
        line_items:[{quantity:1,price_data:{currency:"eur",unit_amount:Math.round(amount*100),tax_behavior:"inclusive",product_data:{name:details.description}},tax_rates:[details.vat]}],
        metadata:{ref,auto_renew:"30d",terms:TERMS_VERSION},
        success_url:PANEL+"?placilo=uspeh&ref="+encodeURIComponent(ref)+"&session_id={CHECKOUT_SESSION_ID}",cancel_url:PANEL+"?placilo=preklic&ref="+encodeURIComponent(ref)});
      return response({url:session.url});
    }
    if(!body.order) throw new Error("Manjkajo podatki narocila.");
    const {data:settings}=await sb.from("rb_billing_settings").select("enabled").eq("id",true).maybeSingle();
    if(!settings?.enabled)throw new Error("Samodejno plačevanje je v pripravi. Prosimo, oddajte povpraševanje.");
    const localToday=new Intl.DateTimeFormat("en-CA",{timeZone:"Europe/Ljubljana",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());
    const {order,amount}=validateOrder(body.order,localToday);
    // Prijavljena stranka lahko naroci samo z e-naslovom svoje prijave.
    const narToken=(req.headers.get("authorization")||"").replace(/^Bearer\s+/i,"");
    const narUser=narToken?(await sb.auth.getUser(narToken).catch(()=>null))?.data?.user:null;
    if(!narUser?.email)return response({error:"Pred plačilom se prijavite."},401);
    if(narUser?.email&&narUser.email.trim().toLowerCase()!==String(order.email))
      throw new Error("Naročilo lahko oddaš samo z e-naslovom, s katerim si prijavljen ("+narUser.email+").");
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
      const details=await invoiceSetup(stripe,order,ref),description=details.description;
      session=await stripe.checkout.sessions.create({locale:"sl",mode:"payment",payment_method_types:["card"],customer:details.customer,payment_intent_data:{setup_future_usage:"off_session"},invoice_creation:{enabled:true,invoice_data:{description,footer:"Rabim d.o.o. · info@rabimbox.si",...(order.davcna?{custom_fields:[{name:"Davčna številka",value:String(order.davcna)}]}:{})}},
        line_items:[{quantity:1,price_data:{currency:"eur",unit_amount:Math.round(amount*100),
          tax_behavior:"inclusive",product_data:{name:description}},tax_rates:[details.vat]}],
        metadata:{draft_id:draft.data.id,ref,auto_renew:"30d",terms:TERMS_VERSION},
        success_url:PAGE+"?placilo=uspeh&ref="+encodeURIComponent(ref)+"&session_id={CHECKOUT_SESSION_ID}",
        cancel_url:PAGE+"?placilo=preklic&ref="+encodeURIComponent(ref)});
    }catch(e){await sb.from("checkout_osnutki").delete().eq("id",draft.data.id);throw e;}
    const link=await sb.from("checkout_osnutki").update({stripe_session_id:session.id}).eq("id",draft.data.id);
    if(link.error) throw link.error;
    return response({url:session.url});
  }catch(e){console.error("Stripe checkout:",e);return response({error:String((e as Error).message||e)},400);}
});
