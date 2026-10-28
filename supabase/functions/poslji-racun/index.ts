// Enoten slovenski PDF plačanega računa za profil, skladišče in e-poštne priponke.
import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
import {invoicePdfData,makeInvoicePdf} from "../_shared/invoice-pdf.ts";

const SUPABASE_URL=Deno.env.get("SUPABASE_URL")??"",SERVICE_ROLE=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
function b64(bytes:Uint8Array){let bin="";for(let i=0;i<bytes.length;i+=8192)bin+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(bin);}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  try{
    const inp=await req.json();
    if(String(inp.tip||"racun").toLowerCase()!=="racun"||!inp.download)throw new Error("Na voljo je samo prenos plačanega računa.");
    if(!inp.stevilka&&!inp.racun_id)throw new Error("Manjka številka računa.");
    const tok=(req.headers.get("authorization")||"").replace(/^Bearer\s+/i,"");
    if(!tok)throw new Error("Ni dovoljeno.");
    const sb=createClient(SUPABASE_URL,SERVICE_ROLE);
    let query=sb.from("racuni").select("*");
    query=inp.racun_id?query.eq("id",inp.racun_id):query.eq("stevilka",inp.stevilka);
    const {data:r,error}=await query.single();
    if(error||!r)throw new Error("Račun ni najden.");
    if(r.placano!==true&&!["placan","poslan","posiljanje"].includes(String(r.status)))throw new Error("Račun je na voljo šele po plačilu.");
    const service=!!SERVICE_ROLE&&tok===SERVICE_ROLE;
    if(!service){
      const {data:auth,error:authError}=await sb.auth.getUser(tok);
      const staff=auth.user?await sb.from("osebje").select("vloga").eq("user_id",auth.user.id).maybeSingle():null;
      if(authError||!auth.user?.email||(auth.user.email.toLowerCase()!==String(r.email||"").toLowerCase()&&staff?.data?.vloga!=="admin"))return json({error:"Ni dovoljeno."},403);
    }
    let order:any=null,address:any=null;
    if(r.narocilo_id){
      const result=await sb.from("narocila").select("naslov,postna_stevilka,mesto,nacin_placila").eq("id",r.narocilo_id).maybeSingle();
      if(result.error)throw result.error;order=result.data;
    }
    if(!r.is_test&&!r.stripe_invoice_id&&order?.nacin_placila==="stripe_kartica")throw new Error("Račun je še v pripravi. Poskusite znova čez nekaj trenutkov.");
    // Naslov naročila ima prednost pred poznejšimi spremembami strankinega profila.
    if(!order?.naslov){const result=await sb.from("kupci").select("naslov,postna_stevilka,kraj").eq("email",r.email).limit(1).maybeSingle();if(result.error)throw result.error;address=result.data;}
    const stripeKey=r.is_test?(Deno.env.get("STRIPE_TEST_SECRET_KEY")||Deno.env.get("STRIPE_SECRET_KEY")||""):(Deno.env.get("STRIPE_SECRET_KEY")||"");
    const data=invoicePdfData(r,order,address,!!r.stripe_invoice_id&&/^[sr]k_test_/.test(stripeKey));
    const pdf=await makeInvoicePdf(data);
    return json({ok:true,pdf:b64(pdf),filename:"Racun-"+data.number+".pdf"});
  }catch(e){return json({error:String((e as Error).message||e)},400);}
});
