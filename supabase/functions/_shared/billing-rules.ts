// Datumi konca so izključujoči: 25.10. + 30 dni = obnova 24.11.
export const PERIOD_DAYS = 30;
export const TERMS_VERSION = "2026-10-23";
export function addDays(value:string, days:number):string {
  if(!validDate(value)) throw new Error("Datum ni veljaven.");
  const d=new Date(value+"T12:00:00Z"); d.setUTCDate(d.getUTCDate()+days); return d.toISOString().slice(0,10);
}
export function validDate(value:unknown):value is string {
  return typeof value==="string" && /^\d{4}-\d{2}-\d{2}$/.test(value) && !isNaN(Date.parse(value+"T12:00:00Z")) && new Date(value+"T12:00:00Z").toISOString().slice(0,10)===value;
}
export function price(tip:string,n:number):number {
  if(!Number.isInteger(n)||n<1||n>5000) throw new Error("Število boxov mora biti celo število med 1 in 5000.");
  if(tip==="izposoja") { const p=({20:69,40:109,60:149,80:189} as Record<number,number>)[n]; if(p)return p; }
  if(tip==="skladiscenje"&&n>=3&&n<=50) return Math.round(n*(n<=10?4.90:n<=25?4.20:3.80)*100)/100;
  throw new Error("Izberite veljaven paket (skladiščenje 3–50 boxov; izposoja 20, 40, 60 ali 80).");
}
export function renewalPrice(tip:string,n:number):number {
  if(!Number.isInteger(n)||n<0||n>5000) throw new Error("Neveljavna količina.");
  if(n===0)return 0;
  if(tip==="skladiscenje")return Math.round(n*(n<=10?4.90:n<=25?4.20:3.80)*100)/100;
  if(tip==="izposoja"&&n<=80)return n<=20?69:n<=40?109:n<=60?149:189;
  throw new Error("Neveljavna storitev.");
}
export function text(v:unknown,max:number,required=false):string {
  if(v!=null&&typeof v!=="string")throw new Error("Besedilo ni veljavno.");
  const s=String(v??"").trim(); if(s.length>max||/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(s)||(required&&!s))throw new Error("Manjkajoč ali predolg podatek.");return s;
}
export function email(v:unknown):string { const s=text(v,254,true).toLowerCase();if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s))throw new Error("E-naslov ni veljaven.");return s; }
export function minDelivery(today:string):string { let d=today,n=0;while(n<3){d=addDays(d,1);const w=new Date(d+"T12:00:00Z").getUTCDay();if(w!==0&&w!==6)n++;}return d; }
export function validateOrder(raw:any,today:string){
  if(!raw||typeof raw!=="object"||Array.isArray(raw))throw new Error("Manjkajo podatki naročila.");
  const tip=text(raw.tip,20,true),n=raw.st_boxov;
  if(typeof n!=="number")throw new Error("Število boxov mora biti število.");
  const amount=price(tip,n),date=text(raw.datum_dostave,10,true),time=text(raw.cas_dostave,5,true);
  if(!validDate(date)||date<minDelivery(today)||date>addDays(today,365)||[0,6].includes(new Date(date+"T12:00:00Z").getUTCDay())||!/^(10|11|12|13|14):00$/.test(time))throw new Error("Termin mora biti prost delovni dan vsaj 3 delovne dni vnaprej.");
  if(raw.obmocje!=="ljubljana")throw new Error("Spletno plačilo je omogočeno za Ljubljano. Za druge kraje oddajte povpraševanje.");
  if(raw.auto_renew_consent!==true||raw.terms_version!==TERMS_VERSION)throw new Error("Potrdite samodejno podaljševanje in bremenitev kartice vsakih 30 dni.");
  const order:Record<string,unknown>={tip,st_boxov:n,email:email(raw.email),datum_dostave:date,cas_dostave:time,paket:(tip==="izposoja"?"Izposoja ":"Skladiščenje ")+n+" boxov",cena_opis:amount.toFixed(2).replace(".",",")+" € / 30 dni",stopnice:false,krhko:false,pomoc_polnjenje:raw.pomoc_polnjenje===true,auto_renew_consent:true,terms_version:TERMS_VERSION};
  for(const f of ["ime","priimek","naslov","mesto","telefon"])order[f]=text(raw[f],f==="naslov"?300:100,true);
  if(!/^\+?[\d ()/.-]{6,30}$/.test(String(order.telefon)))throw new Error("Telefon ni veljaven.");
  for(const f of ["podjetje","davcna","opis_lokacije","enota","postna_stevilka"])order[f]=text(raw[f],f==="opis_lokacije"?2000:200)||null;
  if(order.postna_stevilka&&!/^\d{4}$/.test(String(order.postna_stevilka)))throw new Error("Poštna številka mora imeti 4 številke.");
  return {order,amount};
}
export function invoiceDescription(tip:string,n:number,start:string,endExclusive:string){
  const fmt=(v:string)=>v.split("-").reverse().join(".");return `${tip==="izposoja"?"Izposoja":"Skladiščenje"} ${n} boxov - obdobje od ${fmt(start)} do ${fmt(addDays(endExclusive,-1))}`;
}
export function csvCell(value:unknown){const s=String(value??"");return '"'+(/^[=+@\-\t\r]/.test(s)?"'":"")+s.replace(/"/g,'""')+'"';}
