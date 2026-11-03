import assert from 'node:assert/strict';
import {returnBoxIds,creditNoteParams,validateCardRefund,processBoxRefund,handleBoxRefund} from './box-refunds.ts';
const quote={kind:'initial_delivery',order_id:1,stripe_invoice_id:'in_test',stripe_customer_id:'cus_test',amount_cents:2000,currency:'eur',is_test:true,box_count:10,ordered_box_count:40,accepted_box_count:30,period_start:'2026-10-24',period_end:'2026-11-23'};
function fixture(mode='stripe',failSave=false){
  const state:any={row:{id:'a2f6cf5f-e144-4a76-9ea4-4d731339a70b',order_id:1,status:'prepared',mode,amount_cents:2000,currency:'eur',details:quote,lease_token:null},notes:[],createCount:0,failSave,previewCount:0};
  const client:any={
    invoices:{retrieve:async()=>({id:'in_test',status:'paid',amount_remaining:0,amount_paid:9000,currency:'eur',livemode:false,customer:'cus_test'})},
    customers:{retrieve:async()=>({preferred_locales:['sl']})},
    creditNotes:{preview:async()=>{state.previewCount++;return {total:2000,post_payment_amount:2000,pre_payment_amount:0,currency:'eur'}},
      list:async()=>({data:state.notes,has_more:false}),retrieve:async()=>state.notes[0],
      create:async(params:any,opts:any)=>{state.createCount++;state.params=params;state.options=opts;const cn={id:'cn_test',number:'DOB-1',total:2000,invoice:'in_test',currency:'eur',livemode:false,status:'issued',refund:'re_test',pdf:'https://pay.stripe.com/credit_notes/test/pdf',metadata:params.metadata};state.notes.push(cn);return cn;}},
    refunds:{retrieve:async()=>({id:'re_test',amount:2000,currency:'eur',status:'succeeded'})}
  };
  const sb:any={rpc:async(name:string,args:any)=>{
    assert.equal(name,'rb_claim_box_refund');
    if(state.row.status==='prepared'){if(state.row.lease_token)return {error:{message:'Vračilo se že obdeluje.'}};state.row.lease_token=args.p_token;}
    return {data:structuredClone(state.row),error:null};
  },from:()=>({update:(values:any)=>{
    const q:any={eq:()=>q,select:()=>q,maybeSingle:async()=>{
      if(state.failSave){state.failSave=false;return {error:{message:'DB unavailable'},data:null};}
      Object.assign(state.row,values);return {data:structuredClone(state.row),error:null};
    },then:(resolve:any)=>{Object.assign(state.row,values);resolve({error:null})}};return q;
  }})};
  return {state,client,sb};
}
Deno.test('Box IDs are distinct positive integers in canonical order',()=>{
  assert.deepEqual(returnBoxIds([3,1,2]),[1,2,3]);for(const bad of [[],[1,1],[null],[1.2],[-1],'1'])assert.throws(()=>returnBoxIds(bad));
});
Deno.test('Credit note refunds exact total, disables automatic mail and includes Slovene memo',()=>{
  const p=creditNoteParams(quote,'op');assert.equal(p.amount,2000);assert.equal(p.refund_amount,2000);assert.equal(p.email_type,'none');assert.equal(p.metadata.rabimbox_box_refund,'op');assert.match(p.memo,/naročeno 40, prevzeto 30/);assert.doesNotMatch(p.memo,/dni|Sorazmerno/);
});
Deno.test('Foreign customer and live/test mismatch fail before credit note creation',async()=>{
  const f=fixture();await assert.rejects(()=>validateCardRefund({...quote,stripe_customer_id:'cus_other'},f.client,false),/ne pripada/);
  await assert.rejects(()=>validateCardRefund(quote,f.client,true),/način Stripe/);assert.equal(f.state.createCount,0);
});
Deno.test('Successful card refund creates one credit note and records original refund',async()=>{
  const f=fixture();const result=await processBoxRefund(f.sb,f.state.row,()=>f.client,false);
  assert.equal(result.status,'submitted');assert.equal(result.stripe_refund_id,'re_test');assert.equal(result.provider_status,'succeeded');
  assert.equal(f.state.createCount,1);assert.match(f.state.options.idempotencyKey,/^rb-box-refund-/);
  await processBoxRefund(f.sb,f.state.row,()=>f.client,false);assert.equal(f.state.createCount,1);
});
Deno.test('Lost database response after Stripe success is recovered without another refund',async()=>{
  const f=fixture('stripe',true);await assert.rejects(()=>processBoxRefund(f.sb,f.state.row,()=>f.client,false),/DB unavailable/);
  assert.equal(f.state.row.status,'prepared');assert.equal(f.state.createCount,1);
  const result=await processBoxRefund(f.sb,f.state.row,()=>f.client,false);assert.equal(result.stripe_credit_note_id,'cn_test');assert.equal(f.state.createCount,1);
});
Deno.test('Processing lease excludes concurrent payout',async()=>{
  const f=fixture();f.state.row.lease_token='busy';await assert.rejects(()=>processBoxRefund(f.sb,f.state.row,()=>f.client,false));assert.equal(f.state.createCount,0);
});
Deno.test('Old prorated pending refunds cannot be paid under the new policy',async()=>{
  const f=fixture();f.state.row.details={...quote,kind:undefined,unused_days:20};
  await assert.rejects(()=>processBoxRefund(f.sb,f.state.row,()=>f.client,false),/prvi dostavi/);assert.equal(f.state.createCount,0);
});
Deno.test('Manual and zero refunds never call Stripe',async()=>{
  for(const mode of ['manual','zero']){const f=fixture(mode);const result=await processBoxRefund(f.sb,f.state.row,()=>{throw new Error('Stripe must not be called')},false);assert.equal(result.status,mode==='manual'?'manual':'completed');}
});
Deno.test('Missing confirmation never prepares a return or pays money',async()=>{
  const f=fixture();await assert.rejects(()=>handleBoxRefund('box_refund',{order_id:1,box_ids:[1],expected_amount:2000},f.sb,()=>f.client,null,false),/Potrdite/);assert.equal(f.state.createCount,0);
});
Deno.test('Initial-delivery declaration is required before any payout lookup',async()=>{
  const f=fixture();await assert.rejects(()=>handleBoxRefund('box_refund',{order_id:1,box_ids:[1],expected_amount:2000,confirmed:true},f.sb,()=>f.client,null,false),/neuporabljene odvečne boxe ob prvi dostavi/);assert.equal(f.state.createCount,0);
});
Deno.test('History refreshes an asynchronous Stripe refund without issuing another one',async()=>{
  const f=fixture();f.state.row.status='submitted';f.state.row.provider_status='pending';f.state.row.stripe_refund_id='re_test';
  const sb:any={from:()=>{const q:any={select:()=>q,eq:()=>q,order:()=>q,limit:async()=>({data:[f.state.row],error:null}),update:(changes:any)=>({eq:async()=>{Object.assign(f.state.row,changes);return {error:null}}})};return q;}};
  const result=await handleBoxRefund('box_refund_list',{order_id:1},sb,()=>f.client,null,false);
  assert.equal(result.refunds[0].provider_status,'succeeded');assert.equal(f.state.createCount,0);
});
