import Stripe from "https://esm.sh/stripe@14?target=deno";
import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
import {addDays,invoiceDescription,renewalPrice,text,csvCell,TERMS_VERSION} from "../_shared/billing-rules.ts";
import {sendLoggedMail,escapeHtml as esc} from "../_shared/mail.ts";
import {ensureSlovenianDocuments} from "../_shared/stripe-language.ts";
import {STRIPE_INVOICE_FOOTER} from "../_shared/invoice-issuer.ts";
const URL=Deno.env.get("SUPABASE_URL")||"",KEY=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
const PANEL="https://test.rabimbox.si/moj-profil/";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,apikey,x-client-info,content-type","Access-Control-Allow-Methods":"POST,OPTIONS"};
const json=(v:unknown,status=200)=>new Response(JSON.stringify(v),{status,headers:{...cors,"Content-Type":"application/json"}});
const db=()=>createClient(URL,KEY);
function stripe(test=false){const key=test?(Deno.env.get("STRIPE_TEST_SECRET_KEY")||Deno.env.get("STRIPE_SECRET_KEY")||""):(Deno.env.get("STRIPE_SECRET_KEY")||"");if(!key||test&&!/^[sr]k_test_/.test(key))throw new Error("Za teste je potreben testni ključ Stripe (STRIPE_TEST_SECRET_KEY).");return new Stripe(key,{apiVersion:"2023-10-16",httpClient:Stripe.createFetchHttpClient()});}
const today=()=>new Intl.DateTimeFormat("en-CA",{timeZone:"Europe/Ljubljana",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());
const stamp=(d:string)=>Math.floor(Date.parse(d+"T10:00:00Z")/1000);
const iso=(n:number)=>new Date(n*1000).toISOString().slice(0,10);
const page=(title:string,body:string)=>`<div style="font-family:Arial,sans-serif;max-width:600px;margin:auto;color:#243247"><h1 style="font-size:24px">${esc(title)}</h1>${body}<p><a href="${PANEL}" style="display:inline-block;padding:12px 20px;background:#0067ff;color:white;text-decoration:none;border-radius:8px">Moj račun</a></p><hr><p>Rabimbox · <a href="mailto:info@rabimbox.si">info@rabimbox.si</a></p></div>`;
async function checked<T=any>(p:PromiseLike<{data:T|null;error:any}>):Promise<T>{const r=await p;if(r.error)throw r.error;return r.data as T;}
async function getPrice(client:Stripe,tip:string,n:number,amount:number){
  const key=`rb30-${tip}-${n}-${Math.round(amount*100)}`;
  const list=await client.prices.list({lookup_keys:[key],active:true,limit:1});if(list.data[0])return list.data[0].id;
  const p=await client.prices.create({currency:"eur",unit_amount:Math.round(amount*100),recurring:{interval:"day",interval_count:30},tax_behavior:"inclusive",lookup_key:key,product_data:{name:(tip==="izposoja"?"Izposoja ":"Skladiščenje ")+n+" boxov / 30 dni"},metadata:{rabimbox:"30d",box_count:String(n),tip}},{idempotencyKey:key});return p.id;
}
async function getVat(client:Stripe){const taxes=await client.taxRates.list({active:true,limit:100});const tax=taxes.data.find((t:Stripe.TaxRate)=>t.inclusive&&t.percentage===22&&t.country==="SI")||await client.taxRates.create({display_name:"DDV",percentage:22,inclusive:true,country:"SI"},{idempotencyKey:"rabimbox-vat-si-22-inclusive"});return tax.id;}
export async function startRenewal(session:Stripe.Checkout.Session){
  const sb=db(),ref=session.metadata?.ref;
  if(!ref)throw new Error("Manjka referenca naročila.");
  const o=await checked<any>(sb.from("narocila").select("*").eq("stevilka",ref).single());
  if(o.is_test===true&&session.livemode)throw new Error("Testno naročilo ne sme uporabiti pravega plačila.");
  const sub=await checked<any>(sb.from("narocnine").select("*").eq("narocilo_id",o.id).order("id",{ascending:false}).limit(1).single());
  if(session.metadata?.auto_renew!=="30d")return;
  const client=stripe(o.is_test),start=String(o.datum_dostave).slice(0,10),end=addDays(start,30);
  const customerId=typeof session.customer==="string"?session.customer:session.customer?.id;
  if(customerId)await ensureSlovenianDocuments(client,customerId);
  let subscription:Stripe.Subscription;
  if(sub.stripe_subscription_id){subscription=await client.subscriptions.retrieve(sub.stripe_subscription_id);}
  else{
    const full=await client.checkout.sessions.retrieve(session.id,{expand:["payment_intent","setup_intent","customer"]});
    const intent=(full.mode==="setup"?full.setup_intent:full.payment_intent) as Stripe.PaymentIntent|Stripe.SetupIntent;
    if(full.status!=="complete"||intent?.status!=="succeeded")throw new Error("Potrditev kartice še ni dokončana.");
    const pm=typeof intent?.payment_method==="string"?intent.payment_method:(intent?.payment_method as any)?.id;
    const customer=typeof full.customer==="string"?full.customer:full.customer?.id;
    if(!pm||!customer)throw new Error("Kartica za samodejno podaljšanje ni potrjena.");
    const now=Math.floor(Date.now()/1000),endTs=sub.datum_do&&full.mode==="setup"?stamp(sub.datum_do):stamp(end);
    if(endTs<=now)throw new Error("Obdobje je že poteklo. Potreben je pregled naročila.");
    const amount=renewalPrice(o.tip,sub.st_boxov||o.st_boxov);
    const price=await getPrice(client,o.tip,sub.st_boxov||o.st_boxov,amount);
    // Prvo obdobje je že plačano. Do njegovega konca ni nove bremenitve.
    const config:Stripe.SubscriptionCreateParams={customer,default_payment_method:pm,items:[{price}],collection_method:"charge_automatically",proration_behavior:"none",metadata:{rabimbox_order:String(o.id),ref,prepaid_until:String(sub.datum_do||end),terms:TERMS_VERSION},payment_settings:{save_default_payment_method:"on_subscription"}};
    config.default_tax_rates=[await getVat(client)];
    if(endTs-now>=172800)config.trial_end=endTs;else config.billing_cycle_anchor=endTs;
    subscription=await client.subscriptions.create(config,{idempotencyKey:"rb-renewal-"+o.id});
    await checked(sb.from("narocnine").update({stripe_subscription_id:subscription.id,stripe_customer_id:customer,stripe_price_id:price,auto_renew:true,consent_at:new Date().toISOString(),consent_version:TERMS_VERSION,stripe_period_end:new Date(endTs*1000).toISOString(),billing_status:"active",datum_do:full.mode==="setup"?sub.datum_do:end}).eq("id",sub.id));
    await checked(sb.from("narocila").update({nacin_placila:"stripe_kartica"}).eq("id",o.id));
  }
  if(session.mode!=="setup"){
    const invoiceRef=session.invoice||(await client.checkout.sessions.retrieve(session.id)).invoice;
    if(!invoiceRef)throw new Error("Stripe račun je še v pripravi; potrditev se bo ponovila samodejno.");
    const inv=await client.invoices.retrieve(typeof invoiceRef==="string"?invoiceRef:invoiceRef.id);
    // Obstoječi zapis prvega računa je evidenca istega Stripe računa, ne nov račun.
    await checked(sb.from("racuni").update({stripe_invoice_id:inv.id,stripe_stevilka:inv.number,url_pdf:inv.invoice_pdf,obdobje_od:start,obdobje_do:end,placano:true,opis:invoiceDescription(o.tip,o.st_boxov,start,end)}).eq("narocilo_id",o.id).is("stripe_invoice_id",null));
  }
}
async function reconcileOrder(id:number){
  const sb=db(),o=await checked<any>(sb.from("narocila").select("*").eq("id",id).single());
  const subs=await checked<any[]>(sb.from("narocnine").select("*").eq("narocilo_id",id));
  for(const n of subs){
    if(!n.stripe_subscription_id)continue;
    const client=stripe(n.is_test),remote=await client.subscriptions.retrieve(n.stripe_subscription_id);
    if(remote.status==="canceled")continue;
    if(remote.status==="trialing"&&remote.trial_end!==stamp(n.datum_do)&&stamp(n.datum_do)>Math.floor(Date.now()/1000)+3600){await client.subscriptions.update(remote.id,{trial_end:stamp(n.datum_do),proration_behavior:"none"});await checked(sb.from("narocnine").update({stripe_period_end:new Date(stamp(n.datum_do)*1000).toISOString()}).eq("id",n.id));}
    const timely=await checked<boolean>(sb.rpc("rb_return_stops_renewal",{p_order:id}));
    if(["zakljuceno","preklicano"].includes(o.status)||n.status!=="aktivna"){
      await client.subscriptions.cancel(remote.id,{invoice_now:false,prorate:false});
      await checked(sb.from("narocnine").update({auto_renew:false,billing_status:"canceled",cancel_requested_at:new Date().toISOString()}).eq("id",n.id));continue;
    }
    if(timely){
      // cancel_at je točen konec predplačanega obdobja tudi pri tehničnem trial obdobju.
      if(stamp(n.datum_do)<=remote.current_period_start)await client.subscriptions.cancel(remote.id,{invoice_now:false,prorate:false});else await client.subscriptions.update(remote.id,{cancel_at:stamp(n.datum_do),proration_behavior:"none"});
      await checked(sb.from("narocnine").update({auto_renew:false,billing_status:"odpoved_najavljena",cancel_requested_at:n.cancel_requested_at||new Date().toISOString()}).eq("id",n.id));continue;
    }
    if(n.cancel_requested_at&&remote.cancel_at){
      await client.subscriptions.update(remote.id,{cancel_at_period_end:false,cancel_at:"",proration_behavior:"none"});
      await checked(sb.from("narocnine").update({auto_renew:true,billing_status:"active",cancel_requested_at:null}).eq("id",n.id));
    }
    if(n.naslednje_st_boxov!=null){
      const amount=renewalPrice(n.tip,n.naslednje_st_boxov);
      if(amount===0){if(stamp(n.datum_do)<=remote.current_period_start)await client.subscriptions.cancel(remote.id,{invoice_now:false,prorate:false});else await client.subscriptions.update(remote.id,{cancel_at:stamp(n.datum_do),proration_behavior:"none"});await checked(sb.from("narocnine").update({auto_renew:false,billing_status:"odpoved_najavljena",cancel_requested_at:n.cancel_requested_at||new Date().toISOString()}).eq("id",n.id));continue;}
      const price=await getPrice(client,n.tip,n.naslednje_st_boxov,amount);
      if(remote.items.data[0]?.price.id!==price)await client.subscriptions.update(remote.id,{items:[{id:remote.items.data[0].id,price}],proration_behavior:"none"});
      await checked(sb.from("narocnine").update({stripe_price_id:price}).eq("id",n.id));
    }
  }
}
async function saveInvoice(inv:Stripe.Invoice){
  if(!inv.subscription||(inv.amount_paid===0&&inv.billing_reason==="subscription_create"))return;
  const sid=typeof inv.subscription==="string"?inv.subscription:inv.subscription.id,sb=db();
  const {data:n,error}=await sb.from("narocnine").select("*").eq("stripe_subscription_id",sid).maybeSingle();if(error)throw error;if(!n)return;
  if(inv.livemode!==(n.is_test?false:!(/^[sr]k_test_/.test(Deno.env.get("STRIPE_SECRET_KEY")||""))))throw new Error("Način računa se ne ujema z naročnino.");
  const line=inv.lines.data.find((l:Stripe.InvoiceLineItem)=>l.type==="subscription");if(!line)throw new Error("Manjka obračunsko obdobje.");
  const start=iso(line.period.start),end=iso(line.period.end),o=await checked<any>(sb.from("narocila").select("*").eq("id",n.narocilo_id).single());
  const count=Number(inv.metadata?.rb_box_count||line.metadata?.rb_box_count||line.price?.metadata?.box_count||line.price?.lookup_key?.match(/^rb30-[a-z]+-(\d+)-/)?.[1]||n.naslednje_st_boxov||n.st_boxov),description=invoiceDescription(n.tip,count,start,end);
  const id=await checked<number>(sb.rpc("rb_record_stripe_invoice",{p_data:{subscription_id:sid,invoice_id:inv.id,number:inv.number||inv.id,amount_cents:inv.amount_paid,box_count:count,period_start:start,period_end:end,period_end_ts:new Date(line.period.end*1000).toISOString(),description,issued_at:iso(inv.created),pdf:inv.invoice_pdf}}));
  await invoiceMail(id,o);
}
async function invoiceAttachment(r:any){
  // Prvo plačilo, podaljšanje in prenos uporabljajo isto slovensko predlogo.
  const res=await fetch(URL+"/functions/v1/poslji-racun",{method:"POST",headers:{Authorization:"Bearer "+KEY,apikey:KEY,"Content-Type":"application/json"},body:JSON.stringify({racun_id:r.id,download:true})});
  const data=await res.json();if(!res.ok||!data.pdf)throw new Error("Priponka računa ni pripravljena.");return {filename:data.filename,content:data.pdf};
}
async function invoiceMail(id:number,o:any){
  const sb=db(),r=await checked<any>(sb.from("racuni").select("*").eq("id",id).single());
  if(!r.placano&&!["placan","poslan","posiljanje"].includes(r.status))throw new Error("Račun ni plačan.");
  const logged=await checked<any>(sb.from("rb_email_log").select("status").eq("dedup_key","invoice-"+id).maybeSingle());if(logged&&logged.status!=="napaka"&&logged.status!=="posiljanje")return;
  await sendLoggedMail(r.email,(r.is_test?"[TEST] ":"")+"Račun za novo obdobje – Rabimbox",page("Najem je podaljšan",`<p>Pozdravljeni ${esc(o.ime)}, plačilo za naslednje 30-dnevno obdobje je potrjeno.</p><p>${esc(r.opis)}</p><p>Znesek: ${Number(r.znesek).toFixed(2).replace(".",",")} €.</p><p>${r.is_test?"To je test. Kartica ni bila bremenjena in dokument ni pravi račun.":"Račun se nahaja v priponki."}</p>`),[await invoiceAttachment(r)],"info@rabimbox.si",{key:"invoice-"+r.id,orderId:o.id,invoiceId:r.id,test:r.is_test});
}
async function processEvent(event:Stripe.Event){
  const sb=db();
  const {data:existing}=await sb.from("rb_billing_events").select("processed_at").eq("id",event.id).maybeSingle();if(existing?.processed_at)return;
  await checked(sb.from("rb_billing_events").upsert({id:event.id,type:event.type,error:null},{onConflict:"id"}));
  try{
    if(event.type.startsWith("invoice.")){const eventInvoice=event.data.object as Stripe.Invoice;event.data.object=await stripe(!event.livemode).invoices.retrieve(eventInvoice.id);}
    if(event.type==="invoice.paid")await saveInvoice(event.data.object as Stripe.Invoice);
    if(event.type==="invoice.created"){
      const inv=event.data.object as Stripe.Invoice;
      if(inv.subscription){const sid=typeof inv.subscription==="string"?inv.subscription:inv.subscription.id;const {data:n}=await sb.from("narocnine").select("*").eq("stripe_subscription_id",sid).maybeSingle();if(n){
        const customer=typeof inv.customer==="string"?inv.customer:inv.customer?.id;
        if(customer)await ensureSlovenianDocuments(stripe(n.is_test),customer);
        await reconcileOrder(n.narocilo_id);
        const client=stripe(n.is_test),o=await checked<any>(sb.from("narocila").select("status").eq("id",n.narocilo_id).single());
        const stop=["zakljuceno","preklicano"].includes(o.status)||n.status!=="aktivna"||await checked<boolean>(sb.rpc("rb_return_stops_renewal",{p_order:n.narocilo_id}));
        const line=inv.lines.data.find((l:Stripe.InvoiceLineItem)=>l.type==="subscription");
        if(inv.status==="draft"&&stop){await client.invoices.update(inv.id,{auto_advance:false,metadata:{rabimbox_hold:"Pravočasno vračilo ali zaključek naročila"}});}
        else if(line&&inv.status==="draft"&&line.period.end-line.period.start===30*86400){
          const count=n.naslednje_st_boxov??n.st_boxov,description=invoiceDescription(n.tip,count,iso(line.period.start),iso(line.period.end)),amount=renewalPrice(n.tip,count);
          await client.invoices.update(inv.id,{description,footer:STRIPE_INVOICE_FOOTER,metadata:{rb_box_count:String(count)}});
          // Stripe pri vrstici naročnine dovoljuje samo davčne popravke.
          // Obdobje je v memo opisu in v standardnem izpisu obdobja vrstice.
          const adjustment=Math.round(amount*100)-inv.total;
          if(adjustment!==0){await client.invoiceItems.create({customer:typeof inv.customer==="string"?inv.customer:inv.customer!.id,invoice:inv.id,currency:"eur",amount:adjustment,tax_rates:[await getVat(client)],discountable:false,description:"Uskladitev količine na "+count+" boxov",period:line.period},{idempotencyKey:"rb-adjust-"+inv.id+"-"+amount+"-"+inv.total});}
        }
      }}
    }
    if(event.type==="invoice.payment_failed"||event.type==="invoice.payment_action_required"){
      const inv=event.data.object as Stripe.Invoice,sid=typeof inv.subscription==="string"?inv.subscription:inv.subscription?.id;
      if(sid){const {data:n}=await sb.from("narocnine").select("*").eq("stripe_subscription_id",sid).maybeSingle();if(n){
        await checked(sb.from("narocnine").update({billing_status:"past_due"}).eq("id",n.id));
        const o=await checked<any>(sb.from("narocila").select("*").eq("id",n.narocilo_id).single());
        await sendLoggedMail(o.email,(n.is_test?"[TEST] ":"")+"Plačilo ni uspelo – Rabimbox",page("Prosimo, uredite plačilo",`<p>Pozdravljeni ${esc(o.ime)}, plačilo za novo obdobje ni uspelo. V Mojem računu uredite kartico ali dokončajte plačilo.</p>${inv.hosted_invoice_url?`<p><a href="${esc(inv.hosted_invoice_url)}">Uredi plačilo</a></p>`:""}`),[],"info@rabimbox.si",{key:`failed-${inv.id}-${inv.attempt_count||0}`,orderId:o.id,test:n.is_test});
      }}
    }
    if(event.type==="customer.subscription.deleted"){
      const r=event.data.object as Stripe.Subscription;
      await checked(sb.from("narocnine").update({auto_renew:false,billing_status:"canceled"}).eq("stripe_subscription_id",r.id));
    }
    await checked(sb.from("rb_billing_events").update({processed_at:new Date().toISOString(),error:null}).eq("id",event.id));
  }catch(e){await sb.from("rb_billing_events").update({error:String((e as Error).message).slice(0,500)}).eq("id",event.id);throw e;}
}
async function worker(){
  const sb=db();let processed=0,reminders=0;const errors:Array<{order:number;error:string}>=[];
  const queued=await checked<any[]>(sb.from("rb_billing_queue").select("*").order("updated_at").limit(100));
  for(const q of queued){try{await reconcileOrder(q.narocilo_id);await checked(sb.from("rb_billing_queue").delete().eq("narocilo_id",q.narocilo_id).eq("updated_at",q.updated_at));processed++;}catch(e){const error=String((e as Error).message).slice(0,500);await sb.from("rb_billing_queue").update({error,updated_at:new Date().toISOString()}).eq("narocilo_id",q.narocilo_id).eq("updated_at",q.updated_at);errors.push({order:q.narocilo_id,error});}}
  for(let offset=0;offset<10000;offset+=100){
    const subs=await checked<any[]>(sb.from("narocnine").select("*").not("stripe_subscription_id","is",null).eq("status","aktivna").order("id").range(offset,offset+99));
    for(const n of subs){try{
      const client=stripe(n.is_test),clock=n.is_test&&n.stripe_test_clock_id?await client.testHelpers.testClocks.retrieve(n.stripe_test_clock_id):null;
      const localDay=clock?iso(clock.frozen_time):today();
      const invoices=await client.invoices.list({subscription:n.stripe_subscription_id,limit:10});
      for(const inv of invoices.data.sort((a:Stripe.Invoice,b:Stripe.Invoice)=>a.period_start-b.period_start)){if(inv.status==="paid")await saveInvoice(inv);else if(inv.status==="open"&&inv.attempted)await processEvent({id:"poll-failed-"+inv.id+"-"+inv.attempt_count,type:"invoice.payment_failed",livemode:inv.livemode,data:{object:inv}} as Stripe.Event);}
      if(!n.auto_renew||n.datum_do!==addDays(localDay,5))continue;
      const o=await checked<any>(sb.from("narocila").select("*").eq("id",n.narocilo_id).single());
      if(await checked<boolean>(sb.rpc("rb_return_stops_renewal",{p_order:o.id}))||["zakljuceno","preklicano"].includes(o.status))continue;
      const amount=n.naslednja_cena??n.cena_mesecna;
      const sent=await sendLoggedMail(o.email,(n.is_test?"[TEST] ":"")+"Opomnik: najem se obnovi čez 5 dni – Rabimbox",page("Najem se kmalu podaljša",`<p>Pozdravljeni ${esc(o.ime)}, dne <b>${esc(n.datum_do.split("-").reverse().join("."))}</b> se najem samodejno podaljša za 30 dni. Kartico bomo bremenili za <b>${Number(amount).toFixed(2).replace(".",",")} €</b>.</p><p>Če želite vrniti vse boxe, pravočasno naročite vračilo v Mojem računu, najmanj 3 dni pred obnovo.</p>${n.is_test?"<p>Testno sporočilo: prave bremenitve ni.</p>":""}`),[],"info@rabimbox.si",{key:`renewal-${n.id}-${n.datum_do}`,orderId:o.id,test:n.is_test});
      if(!sent.skipped)reminders++;
    }catch(e){errors.push({order:n.narocilo_id,error:String((e as Error).message).slice(0,500)});}}
    if(subs.length<100)break;
  }
  return {ok:errors.length===0,processed,reminders,errors};
}
const safeSnapshot=(html:string)=>String(html||"").replace(/([?&](?:amp;)?(?:token_hash|token|code|access_token|refresh_token)=)[^&"<\s]+/g,"$1[skrito]");
const mailStatus=(value:string)=>({sent:"poslano",delivered:"dostavljeno",opened:"odprto",clicked:"kliknjeno",bounced:"zavrnjeno",complained:"prijavljeno kot neželeno",failed:"napaka"} as Record<string,string>)[value]||value||"poslano";
async function importEmailHistory(after:string){
  const response=await fetch("https://api.resend.com/emails?limit=100"+(after?"&after="+encodeURIComponent(after):""),{headers:{Authorization:"Bearer "+Deno.env.get("RESEND_API_KEY")}});
  if(!response.ok)throw new Error("Zgodovina pri ponudniku ni dostopna ("+response.status+"). Nova sporočila se še naprej beležijo lokalno.");
  const data=await response.json(),sb=db();let imported=0;
  const ours=(data.data||[]).filter((e:any)=>/@rabimbox\.si[>\s]*$/i.test(e.from||""));
  if(ours.length){
    const existing=await checked<any[]>(sb.from("rb_email_log").select("provider_id").in("provider_id",ours.map((e:any)=>e.id))),ids=new Set(existing.map(e=>e.provider_id));
    const rows=ours.filter((e:any)=>!ids.has(e.id)).map((e:any)=>({provider_id:e.id,dedup_key:"history-"+e.id,recipient:(e.to||[]).join(", "),subject:e.subject,html:null,status:mailStatus(e.last_event),created_at:e.created_at,sent_at:e.created_at}));
    if(rows.length){await checked(sb.from("rb_email_log").upsert(rows,{onConflict:"dedup_key",ignoreDuplicates:true}));imported=rows.length;}
  }
  return {ok:true,imported,after:data.has_more?data.data?.at(-1)?.id:null};
}
async function readEmail(id:number){
  const sb=db(),r=await checked<any>(sb.from("rb_email_log").select("*").eq("id",id).single());
  if(r.provider_id){try{
    const response=await fetch("https://api.resend.com/emails/"+encodeURIComponent(r.provider_id),{headers:{Authorization:"Bearer "+Deno.env.get("RESEND_API_KEY")}});
    if(response.ok){const remote=await response.json(),patch={status:mailStatus(remote.last_event),html:r.html||safeSnapshot(remote.html)};await checked(sb.from("rb_email_log").update(patch).eq("id",r.id));Object.assign(r,patch);}
  }catch(_){/* Lokalni posnetek ostane dostopen tudi ob izpadu ponudnika. */}}
  return {email:r};
}

async function testSetup(){
  const client=stripe(true),sb=db(),result=[];
  for(const fixture of [{email:"miha.tomsiic@gmail.com",name:"Miha",count:20,ref:"TEST-20261023-MIHA"},{email:"maticking31@gmail.com",name:"Matic",count:40,ref:"TEST-20261023-MATIC"}]){
    let o=await checked<any>(sb.from("narocila").select("*").eq("stevilka",fixture.ref).maybeSingle());
    if(!o){
      o=await checked<any>(sb.from("narocila").insert({is_test:true,vir:"rocno",nacin_placila:"stripe_kartica",tip:"izposoja",paket:"TEST – Izposoja "+fixture.count+" boxov",st_boxov:fixture.count,cena_opis:renewalPrice("izposoja",fixture.count)+" € / 30 dni",placano:true,status:"pri_stranki",datum_dostave:addDays(today(),-25),cas_dostave:"11:00",ime:fixture.name,priimek:"Test",email:fixture.email,naslov:"Testni naslov",mesto:"Ljubljana",postna_stevilka:"1000",telefon:"000000000",stevilka:fixture.ref,opis_lokacije:"TEST: brez fizične dostave in brez pravih bremenitev. Boxi iz zaloge niso dodeljeni."}).select("*").single());
    }
    const n=await checked<any>(sb.from("narocnine").select("*").eq("narocilo_id",o.id).limit(1).single());
    if(!n.stripe_subscription_id){
      const clock=await client.testHelpers.testClocks.create({name:fixture.ref,frozen_time:stamp(today())},{idempotencyKey:"clock-"+fixture.ref});
      const customer=await client.customers.create({preferred_locales:["sl"],name:fixture.name+" – TEST",email:fixture.email,test_clock:clock.id,payment_method:"pm_card_visa",invoice_settings:{default_payment_method:"pm_card_visa"},metadata:{rabimbox_test:"true",rabimbox_order:String(o.id)}},{idempotencyKey:"customer-"+fixture.ref});
      const price=await getPrice(client,"izposoja",fixture.count,renewalPrice("izposoja",fixture.count));
      const sub=await client.subscriptions.create({customer:customer.id,default_payment_method:String(customer.invoice_settings.default_payment_method),items:[{price}],trial_end:stamp(n.datum_do),proration_behavior:"none",default_tax_rates:[await getVat(client)],metadata:{rabimbox_order:String(o.id),rabimbox_test:"true",ref:fixture.ref}},{idempotencyKey:"subscription-"+fixture.ref});
      if(sub.livemode)throw new Error("Test ne sme ustvariti prave naročnine.");
      await checked(sb.from("narocnine").update({stripe_customer_id:customer.id,stripe_subscription_id:sub.id,stripe_price_id:price,stripe_test_clock_id:clock.id,stripe_period_end:new Date(stamp(n.datum_do)*1000).toISOString(),auto_renew:true,billing_status:"active",consent_at:new Date().toISOString(),consent_version:"TEST-"+TERMS_VERSION}).eq("id",n.id));
    }
    const initial=await checked<any>(sb.from("racuni").select("id").eq("stevilka",fixture.ref+"-ZACETEK").maybeSingle());
    if(!initial){
      const amount=renewalPrice("izposoja",fixture.count),base=Math.round(amount/1.22*100)/100;
      await checked(sb.from("racuni").insert({stevilka:fixture.ref+"-ZACETEK",narocilo_id:o.id,kupec_id:o.kupec_id,email:fixture.email,ime:fixture.name,priimek:"Test",osnova:base,ddv:Math.round((amount-base)*100)/100,znesek:amount,valuta:"EUR",status:"placan",placano:true,is_test:true,datum_izdaje:today(),datum_zapadlosti:today(),obdobje_od:n.datum_od,obdobje_do:n.datum_do,opis:invoiceDescription("izposoja",fixture.count,n.datum_od,n.datum_do)}));
    }
    result.push({order_id:o.id,ref:fixture.ref,email:fixture.email});
  }
  return {ok:true,orders:result,note:"Testni naročili ne zasedeta fizičnih boxov in ne bremenita pravih kartic."};
}
async function testControl(body:any){
  const sb=db(),n=await checked<any>(sb.from("narocnine").select("*").eq("narocilo_id",Number(body.order_id)).eq("is_test",true).not("stripe_test_clock_id","is",null).single());
  const client=stripe(true),clock=await client.testHelpers.testClocks.retrieve(n.stripe_test_clock_id),op=text(body.operation,30,true);
  if(op==="advance"){
    if(clock.status!=="ready")return {ok:true,clock};
    const days=Number(body.days)||0,hours=Number(body.hours)||0;
    if(!Number.isInteger(days)||days<0||days>60||!Number.isInteger(hours)||hours<0||hours>48||days*24+hours<1)throw new Error("Testni premik mora biti med 1 uro in 60 dnevi.");
    return {ok:true,clock:await client.testHelpers.testClocks.advance(clock.id,{frozen_time:clock.frozen_time+days*86400+hours*3600})};
  }
  if(op==="partial"){
    const count=Number(body.count);if(!Number.isInteger(count)||count<1||count>=n.st_boxov)throw new Error("Izberite manjše pozitivno število testnih boxov.");
    await checked(sb.from("narocnine").update({naslednje_st_boxov:count,naslednja_cena:renewalPrice(n.tip,count),sprememba_od:n.datum_do}).eq("id",n.id));await reconcileOrder(n.narocilo_id);
  }
  if(op==="fail_card"||op==="restore_card"){
    const method=await client.paymentMethods.attach(op==="fail_card"?"pm_card_chargeCustomerFail":"pm_card_visa",{customer:n.stripe_customer_id});
    await client.subscriptions.update(n.stripe_subscription_id,{default_payment_method:method.id,proration_behavior:"none"});
  }
  if(op==="pay_retry"){
    const open=await client.invoices.list({subscription:n.stripe_subscription_id,status:"open",limit:10});for(const inv of open.data)await client.invoices.pay(inv.id);
  }
  if(op==="sync"||op==="pay_retry"){
    const pending=await checked<any[]>(sb.from("rb_billing_events").select("id").is("processed_at",null).order("created_at").limit(50));
    for(const e of pending){if(e.id.startsWith("evt_")){const event=await client.events.retrieve(e.id);await processEvent(event);}}
    const invoices=await client.invoices.list({subscription:n.stripe_subscription_id,limit:20});
    for(const inv of invoices.data){if(inv.status==="paid")await saveInvoice(inv);else if(inv.status==="open"&&inv.attempted)await processEvent({id:"test-poll-failure-"+inv.id+"-"+inv.attempt_count,type:"invoice.payment_failed",data:{object:inv}} as Stripe.Event);}
    await worker();
  }
  const remote=await client.subscriptions.retrieve(n.stripe_subscription_id);
  return {ok:true,clock,subscription:{id:remote.id,status:remote.status,cancel_at:remote.cancel_at,period_start:remote.current_period_start,period_end:remote.current_period_end},invoices:(await client.invoices.list({subscription:n.stripe_subscription_id,limit:10})).data.map((i:Stripe.Invoice)=>({id:i.id,number:i.number,status:i.status,paid:i.amount_paid,due:i.amount_due,period_start:i.lines.data[0]?.period.start,period_end:i.lines.data[0]?.period.end}))};
}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});if(req.method!=="POST")return json({error:"Metoda ni dovoljena."},405);
  try{
    const body=await req.json(),action=text(body.action,50,true),sb=db();
    if(action==="configuration"){const {data}=await sb.from("rb_billing_settings").select("enabled").eq("id",true).maybeSingle();return json({enabled:!!data?.enabled,period_days:30,reminder_days:5});}
    const tok=(req.headers.get("authorization")||"").replace(/^Bearer\s+/i,"");const service=!!KEY&&(tok===KEY||req.headers.get("apikey")===KEY);
    let user:any=null,admin=false;
    if(!service){const r=await sb.auth.getUser(tok);if(r.error||!r.data.user)return json({error:"Prijava je potrebna."},401);user=r.data.user;const staff=await sb.from("osebje").select("vloga").eq("user_id",user.id).maybeSingle();admin=staff.data?.vloga==="admin";}
    if(action==="checkout_completed"){if(!service)return json({error:"Ni dovoljeno."},403);const session=await stripe(body.test===true).checkout.sessions.retrieve(text(body.session_id,200,true));if(session.payment_status!=="paid"&&session.mode!=="setup")throw new Error("Plačilo ni potrjeno.");await startRenewal(session);return json({ok:true});}
    if(action==="event"){if(!service)return json({error:"Ni dovoljeno."},403);await processEvent(body.event);return json({ok:true});}
    if(action==="worker"){if(!service)return json({error:"Ni dovoljeno."},403);return json(await worker());}
    if(action==="portal"){
      const o=await checked<any>(sb.from("narocila").select("id,email,is_test").eq("id",Number(body.order_id)).single());
      if(!admin&&(!user||o.email.toLowerCase()!==user.email.toLowerCase()))return json({error:"Ni dovoljeno."},403);
      const n=await checked<any>(sb.from("narocnine").select("stripe_customer_id").eq("narocilo_id",o.id).not("stripe_customer_id","is",null).limit(1).single());
      const client=stripe(o.is_test),configs=await client.billingPortal.configurations.list({active:true,limit:100});
      const cfg=configs.data.find((c:any)=>c.metadata?.rabimbox==="30d")||await client.billingPortal.configurations.create({metadata:{rabimbox:"30d"},business_profile:{headline:"Rabimbox – kartica in računi"},features:{payment_method_update:{enabled:true},invoice_history:{enabled:false}}},{idempotencyKey:"rb-portal-30d"});
      await ensureSlovenianDocuments(client,n.stripe_customer_id);
      const p=await client.billingPortal.sessions.create({customer:n.stripe_customer_id,locale:"sl",return_url:PANEL,configuration:cfg.id});return json({url:p.url});
    }
    if(action==="enroll"){
      if(body.consent!==true||body.terms_version!==TERMS_VERSION)throw new Error("Potrdite samodejno plačilo vsakih 30 dni.");
      const o=await checked<any>(sb.from("narocila").select("*").eq("id",Number(body.order_id)).single());
      if(!user||o.email.toLowerCase()!==user.email.toLowerCase())return json({error:"Ni dovoljeno."},403);
      if(["zakljuceno","preklicano"].includes(o.status)||!o.placano)throw new Error("Za to naročilo kartice ni mogoče vključiti.");
      const n=await checked<any>(sb.from("narocnine").select("*").eq("narocilo_id",o.id).order("id",{ascending:false}).limit(1).single());
      if(n.auto_renew)throw new Error("Samodejno plačilo je že vključeno.");if(!n.datum_do||n.datum_do<=today())throw new Error("Obdobje je že poteklo; kontaktirajte nas.");
      const client=stripe(o.is_test),customer=n.stripe_customer_id|| (await client.customers.create({preferred_locales:["sl"],email:o.email,name:[o.ime,o.priimek].filter(Boolean).join(" "),metadata:{rabimbox_order:String(o.id)}},{idempotencyKey:"rb-enroll-customer-"+o.id})).id;
      await ensureSlovenianDocuments(client,customer);
      const session=await client.checkout.sessions.create({locale:"sl",mode:"setup",currency:"eur",customer,payment_method_types:["card"],metadata:{ref:o.stevilka,auto_renew:"30d",terms:TERMS_VERSION},success_url:PANEL+"?placilo=kartica&session_id={CHECKOUT_SESSION_ID}",cancel_url:PANEL});return json({url:session.url});
    }
    if(!admin&&!service)return json({error:"Samo administrator."},403);
    if(action==="test_setup")return json(await testSetup());
    if(action==="test_control")return json(await testControl(body));
    if(action==="health")return json({ok:true,mode:/^[sr]k_test_/.test(Deno.env.get("STRIPE_SECRET_KEY")||"")?"test":"live",test_key:!!Deno.env.get("STRIPE_TEST_SECRET_KEY"),webhook:!!Deno.env.get("STRIPE_WEBHOOK_SECRET"),period_days:30});
    if(action==="configure"){
      const client=stripe(),endpoints=await client.webhookEndpoints.list({limit:100}),target=endpoints.data.find((e:Stripe.WebhookEndpoint)=>e.url.toLowerCase()===(URL+"/functions/v1/stripe-webhook").toLowerCase());
      if(!target)throw new Error("Manjka obstoječi Stripe webhook. Nastavite ga v Stripe Dashboard.");
      const events=["checkout.session.completed","checkout.session.async_payment_succeeded","invoice.created","invoice.paid","invoice.payment_failed","invoice.payment_action_required","customer.subscription.deleted"];
      await client.webhookEndpoints.update(target.id,{url:URL+"/functions/v1/Stripe-webhook",disabled:false,...(!target.enabled_events.includes("*")?{enabled_events:[...new Set([...target.enabled_events,...events])] as any}:{})});
      // Kontakt na računih nastavimo v invoice footer; API ne ureja lastnega poslovnega profila računa Stripe.
      if(body.enable===true)await checked(sb.from("rb_billing_settings").update({enabled:true,updated_at:new Date().toISOString()}).eq("id",true));
      return json({ok:true,webhook:"enabled",enabled:body.enable===true});
    }
    if(action==="admin_list"){
      const offset=Math.max(0,Math.min(100000,Math.floor(Number(body.offset)||0))),section=body.section||"all";
      if(!["all","emails","invoices"].includes(section))throw new Error("Neveljaven zavihek.");
      const [emails,invoices]=await Promise.all([section!=="invoices"?checked<any[]>(sb.from("rb_email_log").select("id,recipient,subject,status,error,created_at,sent_at,attachment_name,narocilo_id,racun_id,is_test").order("id",{ascending:false}).range(offset,offset+100)):Promise.resolve([]),section!=="emails"?checked<any[]>(sb.from("racuni").select("*").order("id",{ascending:false}).range(offset,offset+100)):Promise.resolve([])]);
      return json({emails:emails.slice(0,100),invoices:invoices.slice(0,100),has_more:emails.length>100||invoices.length>100});
    }
    if(action==="document_language"){
      const linked=await checked<any[]>(sb.from("narocnine").select("stripe_customer_id,is_test").not("stripe_customer_id","is",null));
      const result={ok:true,language:"sl",checked:0,changed:0,errors:[] as string[]};
      for(const test of [false,true]){
        const client=stripe(test),ids=new Set<string>(linked.filter(n=>!!n.is_test===test).map(n=>n.stripe_customer_id));
        // Dodamo tudi prvotna plačila brez povezane naročnine; drugih Stripe strank ne spreminjamo.
        for await(const c of client.customers.list({limit:100})){if(c.metadata?.rabimbox_ref||c.metadata?.rabimbox_order||c.metadata?.rabimbox_test)ids.add(c.id);}
        for(const id of ids){try{result.checked++;if(body.apply===true&&await ensureSlovenianDocuments(client,id))result.changed++;}catch(e){result.errors.push(id+": "+(e as Error).message);}}
      }
      result.ok=result.errors.length===0;return json(result);
    }
    if(action==="history_import")return json(await importEmailHistory(text(body.after,100)));
    if(action==="admin_email")return json(await readEmail(Number(body.id)));
    if(action==="resend"){
      const r=await checked<any>(sb.from("rb_email_log").select("*").eq("id",Number(body.id)).single());
      if(r.html?.includes("[skrito]"))throw new Error("Vabilo vsebuje enkratno povezavo. Uporabite obnovitev gesla.");
      if(!r.html)throw new Error("Izvirna vsebina ni več na voljo. Ponovnega pošiljanja ni mogoče izvesti.");
      const attachments=[];
      if(r.racun_id){const invoice=await checked<any>(sb.from("racuni").select("*").eq("id",r.racun_id).single());attachments.push(await invoiceAttachment(invoice));}
      else if(r.attachment_name)throw new Error("Izvirna priponka ni več na voljo.");
      await sendLoggedMail(r.recipient,r.subject,r.html,attachments,"info@rabimbox.si",{key:"resend-"+r.id+"-"+crypto.randomUUID(),orderId:r.narocilo_id,invoiceId:r.racun_id,test:r.is_test});return json({ok:true});
    }
    if(action==="contacts"){
      const list:any[]=[];for(let offset=0;offset<100000;offset+=1000){const part=await checked<any[]>(sb.from("kupci").select("ime,priimek,email,marketing_consent,marketing_consent_at,marketing_unsubscribed_at").order("id").range(offset,offset+999));list.push(...part);if(part.length<1000)break;}
      const unique=new Map<string,any>();for(const c of list){if(!c.email)continue;if(body.marketing===true&&(!c.marketing_consent||c.marketing_unsubscribed_at))continue;unique.set(String(c.email).trim().toLowerCase(),c);}
      const csv="\uFEFF"+[["Ime","Priimek","E-pošta","Privolitev","Datum privolitve","Odjava"],...[...unique.values()].map(c=>[c.ime,c.priimek,c.email,c.marketing_consent?"da":"ne",c.marketing_consent_at,c.marketing_unsubscribed_at])].map(row=>row.map(csvCell).join(";")).join("\r\n");return json({csv,count:unique.size});
    }
    throw new Error("Neznana zahteva.");
  }catch(e){console.error("Billing:",String((e as Error).message));return json({error:String((e as Error).message||e)},400);}
});
