import {strict as assert} from "node:assert";
import {invoicePdfData} from "./invoice-pdf.ts";
const r={stevilka:"RB-REFERENCA",stripe_stevilka:"3RNBVEZM-0020",stripe_invoice_id:"in_test",ime:"Matic",priimek:"Jančar",email:"test@example.invalid",osnova:12.05,ddv:2.65,znesek:14.7,datum_izdaje:"2026-10-28",obdobje_od:"2026-11-02",obdobje_do:"2026-12-02",opis:"Skladiščenje 3 boxov - obdobje od 02.11.2026 do 01.12.2026",placano:true};
Deno.test("ista številka in zneski, obdobje izključujočega konca prikaže zadnji dan",()=>{
  const d=invoicePdfData(r);
  assert.equal(d.number,r.stripe_stevilka);assert.equal(d.description,"Skladiščenje 3 boxov");
  assert.equal(d.periodEnd,"2026-12-01");assert.equal(d.periodStart,"2026-11-02");
  assert.deepEqual([d.netCents,d.taxCents,d.totalCents],[1205,265,1470]);
  assert.equal(invoicePdfData({...r,obdobje_do:"2027-01-01"}).periodEnd,"2026-12-31");
});
Deno.test("naslov naročila ima prednost in ne doda stare poštne številke iz profila",()=>{
  const d=invoicePdfData(r,{naslov:"Naslov naročila",mesto:"Slovenia",postna_stevilka:null},{naslov:"Stari naslov",postna_stevilka:"1000",kraj:"Ljubljana"});
  assert(d.customerLines.includes("Naslov naročila"));assert(d.customerLines.includes("Slovenija"));
  assert(!d.customerLines.join().includes("1000"));assert(!d.customerLines.join().includes("Stari naslov"));
  assert(invoicePdfData(r,null,{naslov:"Arhivski naslov",postna_stevilka:"1000",kraj:"Ljubljana"}).customerLines.includes("1000 Ljubljana"));
});
Deno.test("testni način je izrecno označen, poslovni prejemnik ohrani kontakt in DDV",()=>{
  const d=invoicePdfData({...r,podjetje:"Podjetje čšž d.o.o.",davcna:"SI12345678"},null,null,true);
  assert(d.test);assert(d.card);assert.equal(d.customer,"Podjetje čšž d.o.o.");
  assert(d.customerLines.includes("Matic Jančar"));assert(d.customerLines.includes("ID za DDV: SI12345678"));
  assert(!invoicePdfData(r).test);assert(invoicePdfData({...r,is_test:true}).test);
});
Deno.test("ne ustvari računa z neusklajenimi, negativnimi ali neveljavnimi zneski",()=>{
  assert.throws(()=>invoicePdfData({...r,znesek:15}),/ne ujemajo/);
  assert.throws(()=>invoicePdfData({...r,osnova:-1}),/niso veljavni/);
  assert.throws(()=>invoicePdfData({...r,ddv:"neveljavno"}),/niso veljavni/);
});
