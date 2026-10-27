import {strict as assert} from "node:assert";
import {ensureSlovenianDocuments} from "./stripe-language.ts";

Deno.test("stari stranki nastavi samo jezik dokumentov, brez bremenitve",async()=>{
  const calls:any[]=[];
  const client={customers:{retrieve:async(id:string)=>({id,preferred_locales:["en"]}),update:async(...args:any[])=>{calls.push(args);}}};
  assert.equal(await ensureSlovenianDocuments(client,"cus_existing"),true);
  assert.deepEqual(calls,[["cus_existing",{preferred_locales:["sl"]}]]);
});
Deno.test("slovenska in izbrisana stranka ne povzročita posodobitve",async()=>{
  let updates=0;
  const client={customers:{retrieve:async(id:string)=>id==="deleted"?{deleted:true}:{preferred_locales:["sl","en"]},update:async()=>{updates++;}}};
  assert.equal(await ensureSlovenianDocuments(client,"sl"),false);
  assert.equal(await ensureSlovenianDocuments(client,"deleted"),false);
  assert.equal(updates,0);
});
Deno.test("napaka nastavitve jezika ni prikrita kot uspeh",async()=>{
  const client={customers:{retrieve:async()=>({preferred_locales:[]}),update:async()=>{throw new Error("Stripe ni dosegljiv");}}};
  await assert.rejects(()=>ensureSlovenianDocuments(client,"cus_existing"),/ni dosegljiv/);
});
