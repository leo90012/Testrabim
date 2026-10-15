// Rocni profil in narocilo. Klice ga lahko samo prijavljeno osebje.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const URL=Deno.env.get("SUPABASE_URL")||"";
const KEY=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(v:unknown,status=200)=>new Response(JSON.stringify(v),{status,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  try{
    const token=(req.headers.get("authorization")||"").replace(/^Bearer\s+/i,"");
    if(!token) return json({error:"Prijava je obvezna."},401);
    const sb=createClient(URL,KEY);
    const auth=await sb.auth.getUser(token);
    if(auth.error||!auth.data.user) return json({error:"Prijava ni veljavna."},401);
    const staff=await sb.from("osebje").select("vloga").eq("user_id",auth.data.user.id).maybeSingle();
    if(staff.error||!staff.data) return json({error:"Samo osebje lahko ustvari ročni vnos."},403);
    const input=await req.json().catch(()=>({}));
    const ime=String(input.ime||"").trim().slice(0,100);
    const priimek=String(input.priimek||"").trim().slice(0,100);
    const email=String(input.email||"").trim().toLowerCase();
    const telefon=String(input.telefon||"").trim().slice(0,100);
    const naslov=String(input.naslov||"").trim().slice(0,300);
    const posta=String(input.postna_stevilka||"").trim().slice(0,30);
    const mesto=String(input.mesto||"").trim().slice(0,100);
    if(!ime||!priimek||!telefon||!naslov||!posta||!mesto||!/^\S+@\S+\.\S+$/.test(email))
      throw new Error("Izpolnite ime, priimek, e-naslov, telefon in naslov.");
    const onlyProfile=input.only_profile===true;
    const tip=String(input.tip||"");
    const n=Number(input.st_boxov);
    const date=String(input.datum_dostave||"");
    const time=String(input.cas_dostave||"");
    if(!onlyProfile){
      if(!["izposoja","skladiscenje"].includes(tip)||!Number.isInteger(n)||n<1||n>360)
        throw new Error("Neveljavna storitev ali stevilo boxov.");
      if(tip==="izposoja"&&![20,40,60,80].includes(n))
        throw new Error("Pri izposoji izberite paket 20, 40, 60 ali 80 boxov.");
      if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||!/^\d{2}:\d{2}$/.test(time))
        throw new Error("Izberite termin dostave.");
      const occupied=await sb.rpc("zasedeni_termini",{d:date});
      if(occupied.error) throw occupied.error;
      if((occupied.data||[]).some((s:unknown)=>String(s).slice(0,2)===time.slice(0,2)))
        throw new Error("Izbrani termin je zaseden.");
      const stock=await sb.from("skatle").select("id",{head:true,count:"exact"})
        .eq("status","na_zalogi").is("kupec_id",null);
      if(stock.error) throw stock.error;
      if((stock.count||0)<n) throw new Error("Trenutno ni dovolj prostih boxov.");
    }
    // Povezavo za nastavitev gesla ustvarimo sami (Supabase je ne poslje), nato jo
    // posljemo v nasem slovenskem sporocilu. Panel jo potrdi sele ob odprtju strani.
    const dostop=await pripraviDostop(sb,email);
    let customer=await sb.from("kupci").select("id").ilike("email",email).maybeSingle();
    if(customer.error) throw customer.error;
    if(!customer.data){
      customer=await sb.from("kupci").insert({ime,priimek,email,telefon,naslov,
        postna_stevilka:posta,kraj:mesto,status_narocnine:"neaktivna"}).select("id").single();
      if(customer.error) throw customer.error;
    }
    if(onlyProfile){
      const poslano=await posljiDostop(email,ime,dostop,null);
      return json({ok:true,kupec_id:customer.data.id,povabilo:poslano.ok,email_napaka:poslano.napaka});
    }
    const amount=tip==="skladiscenje"
      ?Math.round(n*(n<=10?4.90:n<=25?4.20:3.80)*100)/100
      :({20:69,40:109,60:149,80:189} as Record<number,number>)[n];
    const ref="RB-R-"+new Date().getFullYear()+"-"+crypto.randomUUID().slice(0,10).toUpperCase();
    const order=await sb.from("narocila").insert({
      tip,paket:(tip==="izposoja"?"Izposoja ":"Skladiščenje ")+n+" boxov",
      st_boxov:n,cena_opis:amount.toFixed(2).replace(".",",")+" €/mesec",
      ime,priimek,email,telefon,naslov,postna_stevilka:posta,mesto,
      datum_dostave:date,cas_dostave:time,
      opis_lokacije:String(input.opomba||"").slice(0,1000),
      stevilka:ref,vir:"rocno",placano:false,status:"nova",kupec_id:customer.data.id,
    }).select("id,stevilka").single();
    if(order.error) throw order.error;
    const poslano=await posljiDostop(email,ime,dostop,{stevilka:order.data.stevilka,tip,n,date,time,amount});
    return json({ok:true,narocilo_id:order.data.id,stevilka:order.data.stevilka,
      povabilo:poslano.ok,email_napaka:poslano.napaka});
  }catch(e){console.error("Rocni vnos:",e);return json({error:String((e as Error).message||e)},400);}
});

// ---------- Dostop do Mojega profila in e-posta stranki ----------
const PANEL="https://test.rabimbox.si/moj-profil/";
const RESEND_API_KEY=Deno.env.get("RESEND_API_KEY")||"";
const FROM="Rabimbox <narocila@rabimbox.si>";
type Dostop={link:string;novo:boolean};

// Nov uporabnik: povezava "invite". Obstojeci, ki se se ni prijavil: "recovery" (nastavi geslo).
// Obstojeci, ki ze ima geslo: navadna povezava na prijavo.
async function pripraviDostop(sb:ReturnType<typeof createClient>,email:string):Promise<Dostop>{
  const inv=await sb.auth.admin.generateLink({type:"invite",email,options:{redirectTo:PANEL}});
  if(!inv.error&&inv.data?.properties?.hashed_token)
    return {link:PANEL+"?token_hash="+encodeURIComponent(inv.data.properties.hashed_token)+"&type=invite",novo:true};
  if(inv.error&&!/already|registered|exists/i.test(inv.error.message))
    throw new Error("Povezave za profil ni bilo mogoce ustvariti: "+inv.error.message);
  const rec=await sb.auth.admin.generateLink({type:"recovery",email,options:{redirectTo:PANEL}});
  if(rec.error||!rec.data?.properties?.hashed_token) return {link:PANEL,novo:false};
  if(rec.data.user?.last_sign_in_at) return {link:PANEL,novo:false};
  return {link:PANEL+"?token_hash="+encodeURIComponent(rec.data.properties.hashed_token)+"&type=recovery",novo:true};
}

function esc(x:unknown){return String(x??"").replace(/[&<>"']/g,(m)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[m] as string));}
function datum(d:string){const p=d.split("-");return p.length===3?`${+p[2]}. ${+p[1]}. ${p[0]}`:d;}

async function posljiDostop(email:string,ime:string,d:Dostop,
  nar:{stevilka:string;tip:string;n:number;date:string;time:string;amount:number}|null){
  if(!RESEND_API_KEY) return {ok:false,napaka:"RESEND_API_KEY ni nastavljen."};
  const vrstica=(k:string,v:string)=>`<tr><td style="padding:6px 0;color:#7b8794;font-size:13px">${esc(k)}</td><td style="padding:6px 0;text-align:right;color:#2a3342;font-size:14px;font-weight:600">${esc(v)}</td></tr>`;
  const tabela=nar?`<table style="width:100%;border-collapse:collapse;margin:14px 0 4px">
      ${vrstica("Številka naročila",nar.stevilka)}
      ${vrstica("Storitev",(nar.tip==="izposoja"?"Izposoja":"Skladiščenje")+" – "+nar.n+" boxov")}
      ${vrstica("Termin dostave",datum(nar.date)+" ob "+nar.time)}
      ${vrstica("Cena",nar.amount.toFixed(2).replace(".",",")+" € / mesec")}
    </table>`:"";
  const uvod=nar
    ?`Za vas smo pripravili naročilo pri Rabimbox. Podrobnosti so spodaj, naročilo pa lahko kadarkoli spremljate v svojem profilu.`
    :`Za vas smo pri Rabimbox odprli uporabniški profil, kjer lahko spremljate svoja naročila, bokse in račune.`;
  const korak=d.novo
    ?`<p style="font-size:14px;line-height:1.6;margin:14px 0 0">Za vstop v profil si najprej nastavite geslo s klikom na spodnji gumb.</p>`
    :`<p style="font-size:14px;line-height:1.6;margin:14px 0 0">V profil se prijavite s svojim e-naslovom in geslom.</p>`;
  const gumb=d.novo?"Nastavi geslo in odpri profil":"Prijava v Moj profil";
  const html=`<div style="background:#f4f6f9;padding:24px 0;font-family:Arial,Helvetica,sans-serif;color:#2a3342">
    <div style="max-width:560px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 6px 22px rgba(16,24,40,.06)">
      <div style="background:#6ec1e4;padding:16px 26px;color:#fff;font-size:20px;font-weight:700;letter-spacing:.5px"><img src="https://rabimbox.si/wp-content/uploads/2024/08/cropped-3-270x270.png" alt="" width="34" height="34" style="vertical-align:middle;margin-right:10px;border-radius:6px" />Rabimbox</div>
      <div style="padding:26px">
        <h1 style="font-size:20px;margin:0 0 14px;color:#111">${nar?"Vaše naročilo je pripravljeno":"Vaš profil je pripravljen"}</h1>
        <p style="font-size:14px;line-height:1.6;margin:0">Pozdravljeni${ime?", "+esc(ime):""}!</p>
        <p style="font-size:14px;line-height:1.6;margin:8px 0 0">${uvod}</p>
        ${tabela}${korak}
        <div style="margin:22px 0 6px"><a href="${esc(d.link)}" style="display:inline-block;background:#0067ff;color:#fff;text-decoration:none;font-weight:700;padding:13px 24px;border-radius:8px;font-size:15px">${gumb}</a></div>
        <p style="font-size:12.5px;color:#7b8794;line-height:1.6;margin:14px 0 0">Če gumb ne deluje, kopirajte to povezavo v brskalnik:<br><a href="${esc(d.link)}" style="color:#0067ff;word-break:break-all">${esc(d.link)}</a></p>
        ${d.novo?`<p style="font-size:12.5px;color:#7b8794;line-height:1.6;margin:10px 0 0">Povezava je namenjena samo vam in jo lahko uporabite enkrat. Če je potekla, na strani za prijavo kliknite »Pozabljeno geslo«.</p>`:""}
      </div>
      <div style="padding:16px 26px;border-top:1px solid #eef1f6;color:#7b8794;font-size:12px">
        Rabimbox · <a href="mailto:info@rabimbox.si" style="color:#6ec1e4;text-decoration:none">info@rabimbox.si</a> · +386 (0)40 796 040
      </div>
    </div>
  </div>`;
  const zadeva=nar?`Vaše naročilo ${nar.stevilka} – Rabimbox`:"Vaš profil pri Rabimbox";
  try{
    const r=await fetch("https://api.resend.com/emails",{method:"POST",
      headers:{Authorization:"Bearer "+RESEND_API_KEY,"Content-Type":"application/json"},
      body:JSON.stringify({from:FROM,to:[email],subject:zadeva,html,reply_to:"info@rabimbox.si"})});
    if(!r.ok) return {ok:false,napaka:"E-pošte ni bilo mogoče poslati: "+(await r.text()).slice(0,200)};
    return {ok:true,napaka:null};
  }catch(e){return {ok:false,napaka:"E-pošte ni bilo mogoče poslati: "+String((e as Error).message||e)};}
}
