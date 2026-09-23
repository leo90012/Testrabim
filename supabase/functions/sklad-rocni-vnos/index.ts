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
    // Povabilo odpre racun za prijavo v Moj profil. Obstojeci uporabnik ga ne potrebuje.
    const invite=await sb.auth.admin.inviteUserByEmail(email,{redirectTo:"https://test.rabimbox.si/moj-profil/"});
    if(invite.error&&!/already|registered|exists/i.test(invite.error.message))
      throw new Error("Povabila za profil ni bilo mogoce poslati: "+invite.error.message);
    let customer=await sb.from("kupci").select("id").ilike("email",email).maybeSingle();
    if(customer.error) throw customer.error;
    if(!customer.data){
      customer=await sb.from("kupci").insert({ime,priimek,email,telefon,naslov,
        postna_stevilka:posta,kraj:mesto,status_narocnine:"neaktivna"}).select("id").single();
      if(customer.error) throw customer.error;
    }
    if(onlyProfile) return json({ok:true,kupec_id:customer.data.id,povabilo:!invite.error});
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
    return json({ok:true,narocilo_id:order.data.id,stevilka:order.data.stevilka,
      povabilo:!invite.error});
  }catch(e){console.error("Rocni vnos:",e);return json({error:String((e as Error).message||e)},400);}
});
