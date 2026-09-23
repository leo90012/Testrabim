// Stripe podpisan dogodek sprozi isto potrjevanje kot povratna stran po placilu.
import Stripe from "https://esm.sh/stripe@14?target=deno";
const STRIPE_KEY=Deno.env.get("STRIPE_SECRET_KEY")||"";
const WEBHOOK_KEY=Deno.env.get("STRIPE_WEBHOOK_SECRET")||"";
const URL=Deno.env.get("SUPABASE_URL")||"";
const SERVICE_ROLE=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
Deno.serve(async(req)=>{
  const signature=req.headers.get("stripe-signature");
  let event:Stripe.Event;
  try{
    const stripe=new Stripe(STRIPE_KEY,{apiVersion:"2023-10-16",httpClient:Stripe.createFetchHttpClient()});
    event=await stripe.webhooks.constructEventAsync(await req.text(),signature!,WEBHOOK_KEY);
  }catch(e){
    return new Response("Napačen podpis: "+String((e as Error).message||e),{status:400});
  }
  if(!["checkout.session.completed","checkout.session.async_payment_succeeded"].includes(event.type))
    return new Response(JSON.stringify({received:true}),{headers:{"Content-Type":"application/json"}});
  const session=event.data.object as Stripe.Checkout.Session;
  if(session.payment_status!=="paid")
    return new Response(JSON.stringify({received:true,paid:false}),{headers:{"Content-Type":"application/json"}});
  try{
    const res=await fetch(URL+"/functions/v1/rapid-api",{method:"POST",
      headers:{Authorization:"Bearer "+SERVICE_ROLE,apikey:SERVICE_ROLE,"Content-Type":"application/json"},
      body:JSON.stringify({confirm:true,session_id:session.id})});
    if(!res.ok) throw new Error(await res.text());
    return new Response(JSON.stringify({received:true}),{headers:{"Content-Type":"application/json"}});
  }catch(e){
    console.error("Potrditev Stripe placila:",e);
    return new Response(JSON.stringify({error:"Potrditev ni uspela."}),{status:500,headers:{"Content-Type":"application/json"}});
  }
});
