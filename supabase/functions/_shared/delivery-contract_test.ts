import {strict as assert} from "node:assert";
import {deliveryContractContent,validateContractAttachments,deliveryRequestKey,CONTRACT_MAX_BYTES} from "./delivery-contract.ts";

Deno.test("dostavni mail ohrani zadevo, gumb in dopolni pogodbo brez HTML v imenih",()=>{
  const draft=deliveryContractContent({ime:'Matic <img src=x>',email:'preview@example.invalid',st_boxov:40,st_boxov_dejansko:20});
  assert.equal(draft.subject,"Boxi so pri vas – Rabimbox");
  assert(draft.body.includes('Matic &lt;img src=x&gt;'));assert(!draft.body.includes('<img'));
  assert(draft.body.includes('(20 boxov)'));assert(draft.body.includes('pogodbe, ki ste jo podpisali'));
  assert(draft.body.includes('href="https://test.rabimbox.si/moj-profil/"'));
});
Deno.test("veljavni PDF in skenirane slike ostanejo nespremenjeni",()=>{
  const files=[{filename:'Pogodba.pdf',content:btoa('%PDF-1.7\nTEST')},{filename:'sken.jpg',content:btoa('\xff\xd8\xfftest')},{filename:'sken.png',content:btoa('\x89PNG\r\n\x1a\ntest')}];
  assert.deepEqual(validateContractAttachments(files),files);
});
Deno.test("pogodba je obvezna in preimenovana izvršljiva priponka ni sprejeta",()=>{
  assert.throws(()=>validateContractAttachments([]),/Dodaj/);
  assert.throws(()=>validateContractAttachments([{filename:'pogodba.pdf',content:btoa('MZ executable bytes')}]),/veljaven PDF/);
  assert.throws(()=>validateContractAttachments([{filename:'../sken.pdf',content:btoa('%PDF-1.7')}]),/Ime/);
  assert.throws(()=>validateContractAttachments([{filename:'sken.pdf',content:'%%%='}]),/Vsebina/);
  assert.throws(()=>validateContractAttachments(Array(6).fill({filename:'x.pdf',content:btoa('%PDF-1.7')})),/do 5/);
});
Deno.test("upošteva skupno velikost, ne le posameznih datotek",()=>{
  const content=btoa('%PDF-'+ 'x'.repeat(CONTRACT_MAX_BYTES/2));
  assert.throws(()=>validateContractAttachments([{filename:'a.pdf',content},{filename:'b.pdf',content}]),/največ 10 MB/);
});
Deno.test("ponovitev iste oddaje uporablja isti ključ, druga oddaja svojega",()=>{
  const id='df0d4116-f7a1-40bb-a8d2-187048ca59a0';
  assert.equal(deliveryRequestKey(7,id),deliveryRequestKey(7,id));assert.notEqual(deliveryRequestKey(7,id),deliveryRequestKey(8,id));
  assert.throws(()=>deliveryRequestKey(7,'neveljavno'),/oznaka/);
});
