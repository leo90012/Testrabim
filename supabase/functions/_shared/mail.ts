import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
export function escapeHtml(v:unknown){return String(v??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));}
export async function sendLoggedMail(to:string,subject:string,html:string,attachments:Array<{filename:string;content:string}>=[],replyTo="info@rabimbox.si",context:{key?:string;orderId?:number;invoiceId?:number;test?:boolean}={}){
  if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)||/[\r\n]/.test(subject))throw new Error("Neveljaven prejemnik ali zadeva.");
  const sb=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const key=context.key||crypto.randomUUID();
  // Enkratnih vabil/žetonov ne hranimo v dnevniku.
  const snapshot=html.replace(/([?&](?:amp;)?(?:token_hash|token|code|access_token|refresh_token)=)[^&"<\s]+/g,"$1[skrito]");
  const {data:log,error}=await sb.rpc("rb_claim_email",{p_key:key,p_recipient:to,p_subject:subject,p_html:snapshot,p_order:context.orderId||null,p_invoice:context.invoiceId||null,p_test:!!context.test,p_attachment:attachments.map(a=>a.filename).join(", ")||null});
  if(error)throw error;
  if(!log)return {skipped:true};
  try{
    const r=await fetch("https://api.resend.com/emails",{method:"POST",headers:{Authorization:"Bearer "+(Deno.env.get("RESEND_API_KEY")||""),"Content-Type":"application/json","Idempotency-Key":key},body:JSON.stringify({from:"Rabimbox <narocila@rabimbox.si>",to:[to],subject,html,reply_to:replyTo||"info@rabimbox.si",...(attachments.length?{attachments}:{})})});
    if(!r.ok)throw new Error("Ponudnik e-pošte: "+r.status);
    const out=await r.json();
    const up=await sb.from("rb_email_log").update({provider_id:out.id,status:"poslano",sent_at:new Date().toISOString(),error:null}).eq("id",log);
    if(up.error)throw up.error;
    return out;
  }catch(e){await sb.from("rb_email_log").update({status:"napaka",error:String((e as Error).message).slice(0,500)}).eq("id",log);throw e;}
}
