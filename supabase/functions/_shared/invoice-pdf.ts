import {PDFDocument,rgb,PDFFont} from "https://esm.sh/pdf-lib@1.17.1";
// @ts-ignore paket ima privzeti izvoz v izvajalnem okolju ESM.
import fontkit from "https://esm.sh/@pdf-lib/fontkit@1.1.1";
import {INVOICE_ISSUER as issuer} from "./invoice-issuer.ts";

export type InvoicePdfAssets={regular:Uint8Array;bold:Uint8Array;logo?:Uint8Array};
export type InvoicePdfData={
  number:string;issued:string;periodStart?:string;periodEnd?:string;description:string;
  customer:string;customerLines:string[];netCents:number;taxCents:number;totalCents:number;
  currency:string;test:boolean;card:boolean;
};

function clean(value:unknown){return String(value??"").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g,"").trim();}
function cents(value:unknown){const n=Number(value);if(!Number.isFinite(n)||n<0)throw new Error("Zneski računa niso veljavni.");return Math.round(n*100);}
export function invoicePdfData(r:any,order:any=null,fallbackAddress:any=null,stripeTest=false):InvoicePdfData{
  const netCents=cents(r.osnova),taxCents=cents(r.ddv),totalCents=cents(r.znesek);
  if(netCents+taxCents!==totalCents)throw new Error("Zneski računa se ne ujemajo. Potreben je pregled računa.");
  const person=[r.ime,r.priimek].map(clean).filter(Boolean).join(" ")||"Stranka";
  const street=clean(order?.naslov||fallbackAddress?.naslov);
  const city=clean(order?.mesto||(!order?.naslov?fallbackAddress?.kraj:""));
  const postal=clean(order?.postna_stevilka||(!order?.naslov?fallbackAddress?.postna_stevilka:""));
  const place=[postal,city].filter(Boolean).join(" ").replace(/^(Slovenia|Slovenija)$/i,"Slovenija");
  const periodStart=clean(r.obdobje_od).slice(0,10),periodEnd=clean(r.obdobje_do).slice(0,10);
  // datum_do v obračunu je izključujoč; stranki prikazujemo zadnji vključeni dan.
  const lastDay=periodEnd?new Date(Date.parse(periodEnd+"T12:00:00Z")-86400000).toISOString().slice(0,10):"";
  let description=clean(r.opis)||"Storitev Rabimbox";
  if(periodStart&&lastDay)description=description.replace(/\s*-\s*obdobje od \d{2}\.\d{2}\.\d{4} do \d{2}\.\d{2}\.\d{4}\s*$/i,"");
  return {
    number:clean(r.stripe_stevilka||r.stevilka),issued:clean(r.datum_izdaje).slice(0,10),
    periodStart:periodStart||undefined,periodEnd:lastDay||undefined,description,
    customer:clean(r.podjetje)||person,
    customerLines:[r.podjetje?person:"",street,place,clean(r.email),r.davcna?"ID za DDV: "+clean(r.davcna):""].filter(Boolean),
    netCents,taxCents,totalCents,currency:clean(r.valuta)||"EUR",test:r.is_test===true||stripeTest,card:!!r.stripe_invoice_id,
  };
}

let assetsPromise:Promise<InvoicePdfAssets>|undefined;
async function asset(url:string){const r=await fetch(url,{signal:AbortSignal.timeout(12000)});if(!r.ok)throw new Error("Pisava računa trenutno ni dostopna.");return new Uint8Array(await r.arrayBuffer());}
export async function invoicePdfAssets():Promise<InvoicePdfAssets>{
  if(!assetsPromise)assetsPromise=Promise.all([
    asset("https://cdn.jsdelivr.net/npm/dejavu-fonts-ttf@2.37.3/ttf/DejaVuSans.ttf"),
    asset("https://cdn.jsdelivr.net/npm/dejavu-fonts-ttf@2.37.3/ttf/DejaVuSans-Bold.ttf"),
    asset("https://rabimbox.si/wp-content/uploads/2024/08/cropped-3-270x270.png").catch(()=>undefined),
  ]).then(([regular,bold,logo])=>({regular:regular!,bold:bold!,logo})).catch(e=>{assetsPromise=undefined;throw e;});
  return await assetsPromise;
}

export function wrapInvoiceText(value:string,font:PDFFont,size:number,width:number):string[]{
  const lines:string[]=[];
  for(const paragraph of value.split(/\r?\n/)){
    let line="";
    for(const word of paragraph.split(/\s+/).filter(Boolean)){
      if(line&&font.widthOfTextAtSize(line+" "+word,size)<=width){line+=" "+word;continue;}
      if(line){lines.push(line);line="";}
      let part="";
      for(const char of word){if(part&&font.widthOfTextAtSize(part+char,size)>width){lines.push(part);part="";}part+=char;}
      line=part;
    }
    lines.push(line);
  }
  return lines.length?lines:[""];
}

export async function makeInvoicePdf(data:InvoicePdfData,assets?:InvoicePdfAssets):Promise<Uint8Array>{
  assets=assets||await invoicePdfAssets();
  const doc=await PDFDocument.create();doc.registerFontkit(fontkit);
  doc.setTitle("Račun "+data.number);doc.setAuthor(issuer.name);doc.setSubject(data.description);doc.setLanguage("sl-SI");
  const font=await doc.embedFont(assets.regular,{subset:true}),bold=await doc.embedFont(assets.bold,{subset:true});
  let logo:any;try{if(assets.logo)logo=await doc.embedPng(assets.logo);}catch{/* Besedilna znamka ostane tudi brez slike. */}
  const W=595.28,H=841.89,M=44,R=W-M,BOTTOM=708;
  const dark=rgb(.13,.18,.24),muted=rgb(.39,.45,.51),blue=rgb(.19,.55,.7),light=rgb(.94,.97,.99),line=rgb(.84,.89,.92);
  let page=doc.addPage([W,H]),y=0;
  const money=(c:number)=>new Intl.NumberFormat("sl-SI",{style:"currency",currency:data.currency}).format(c/100).replace(/\u00a0/g," ");
  const date=(s?:string)=>s&&/^\d{4}-\d{2}-\d{2}$/.test(s)?s.slice(8,10)+"."+s.slice(5,7)+"."+s.slice(0,4):s||"";
  const T=(text:string,x:number,top:number,size=10,f=font,color=dark)=>page.drawText(text,{x,y:H-top,size,font:f,color});
  const RT=(text:string,right:number,top:number,size=10,f=font,color=dark)=>T(text,right-f.widthOfTextAtSize(text,size),top,size,f,color);
  const HR=(top:number,left=M,right=R)=>page.drawLine({start:{x:left,y:H-top},end:{x:right,y:H-top},thickness:.65,color:line});
  function header(continued=false){
    if(continued){T("Rabimbox",M,42,17,bold,blue);RT(data.number,R,42,10,bold);HR(57);y=80;return;}
    if(logo)page.drawImage(logo,{x:M,y:H-82,width:38,height:38});
    const bx=logo?M+48:M;T("Rabimbox",bx,64,23,bold,dark);T("Skladiščenje in izposoja boxov",bx,81,8.5,font,muted);
    RT("RAČUN",R,56,22,bold);RT(data.number,R,76,10.5,bold);
    RT("Datum izdaje: "+date(data.issued),R,95,9,font,muted);HR(114);y=137;
    if(data.test){page.drawRectangle({x:M,y:H-y-9,width:R-M,height:25,color:rgb(1,.96,.86)});T("TESTNI DOKUMENT - BREZ PRAVE BREMENITVE",M+10,y+7,9,bold,rgb(.48,.34,.12));y+=45;}
  }
  function newPage(){page=doc.addPage([W,H]);header(true);}
  function ensure(height:number){if(y+height>BOTTOM)newPage();}
  function block(title:string,name:string,lines:string[],x:number,width:number){
    let by=y;T(title,x,by,8.5,bold,blue);by+=21;
    for(const s of wrapInvoiceText(name,bold,11,width)){T(s,x,by,11,bold);by+=15;}
    by+=3;
    for(const v of lines)for(const s of wrapInvoiceText(v,font,9.3,width)){T(s,x,by,9.3,font,muted);by+=14;}
    return by;
  }
  header();
  const companyBottom=block("IZDAJATELJ",issuer.name,["Proletarska cesta 4","1000 Ljubljana, Slovenija","ID za DDV: "+issuer.vat,"Matična številka: "+issuer.registration],M,236);
  const customerBottom=block("PREJEMNIK",data.customer,data.customerLines,320,231);
  y=Math.max(companyBottom,customerBottom)+20;
  ensure(94);
  page.drawRectangle({x:M,y:H-y-58,width:R-M,height:58,color:light});
  T(data.test?"SIMULIRANO PLAČILO":"PLAČANO",M+14,y+19,8.5,bold,blue);
  T(money(data.totalCents),M+14,y+43,21,bold);
  RT(data.card?"Plačilo s kartico prek Stripe":"Plačilo potrjeno",R-14,y+23,9.5,font,muted);
  RT("Preostalo za plačilo: "+money(0),R-14,y+42,9,font,muted);y+=81;
  if(data.periodStart&&data.periodEnd){T("OBDOBJE STORITVE",M,y,8.5,bold,blue);RT(date(data.periodStart)+" - "+date(data.periodEnd),R,y,10,bold);y+=25;}
  function tableHeader(){
    page.drawRectangle({x:M,y:H-y-24,width:R-M,height:24,color:light});
    T("Opis storitve",M+8,y+16,9,bold);RT("Kol.",340,y+16,8.5,bold);RT("Cena brez DDV",439,y+16,8.2,bold);RT("Znesek brez DDV",R-8,y+16,8.2,bold);y+=43;
  }
  ensure(72);tableHeader();
  const rows=wrapInvoiceText(data.description,font,10,260);let index=0;
  while(index<rows.length){
    if(y+18>BOTTOM){newPage();tableHeader();}
    T(rows[index],M+8,y,10);
    if(index===0){RT("1",340,y,10);RT(money(data.netCents),439,y,10);RT(money(data.netCents),R-8,y,10);}
    index++;y+=15;
  }
  y+=10;HR(y);y+=25;
  ensure(145);
  const summaryX=319;
  const totalRow=(label:string,value:number,heavy=false)=>{T(label,summaryX,y,10,heavy?bold:font,heavy?dark:muted);RT(money(value),R-8,y,10,heavy?bold:font);y+=23;};
  totalRow("Osnova brez DDV",data.netCents);
  const is22=data.taxCents>0&&Math.abs(data.taxCents-Math.round(data.netCents*.22))<=1;
  totalRow(is22?"DDV (22 %)":"DDV",data.taxCents);HR(y-8,summaryX,R);y+=9;
  totalRow("Skupaj z DDV",data.totalCents,true);totalRow("Preostalo za plačilo",0,true);
  const pages=doc.getPages();
  for(let i=0;i<pages.length;i++){
    page=pages[i];HR(742);T("BANČNI PODATKI",M,762,8,bold,blue);T(issuer.iban,M,779,9);T(issuer.bank+" · SWIFT: "+issuer.swift,M,794,8.3,font,muted);
    T("KONTAKT",320,762,8,bold,blue);T(issuer.email,320,779,9);T(issuer.phone,320,794,9,font,muted);
    T(data.number,M,824,7.5,font,muted);RT("Stran "+(i+1)+" od "+pages.length,R,824,7.5,font,muted);
  }
  return await doc.save();
}
