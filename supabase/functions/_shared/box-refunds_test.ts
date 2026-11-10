import assert from 'node:assert/strict';
import {handleBoxRefund} from './box-refunds.ts';
Deno.test('Every old refund mutation is blocked before any database or Stripe action',async()=>{
  for(const action of ['box_refund_preview','box_refund','box_refund_retry']){
    await assert.rejects(()=>handleBoxRefund(action,{order_id:1},{from(){throw Error('DB must not be called')}},()=>{throw Error('Stripe must not be called')},null,false),/uredite ročno/);
  }
});
Deno.test('History requires a valid order',async()=>{
  await assert.rejects(()=>handleBoxRefund('box_refund_list',{order_id:-1},{},()=>null,null,false),/Naročilo ni veljavno/);
});
Deno.test('Final historical refunds do not call Stripe',async()=>{
  const rows=[{status:'submitted',stripe_refund_id:'re_old',provider_status:'succeeded'}];
  const q:any={select:()=>q,eq:()=>q,order:()=>q,limit:async()=>({data:rows})};
  const result=await handleBoxRefund('box_refund_list',{order_id:1},{from:()=>q},()=>{throw Error('Stripe must not be called')},null,false);
  assert.equal(result.refunds.length,1);
});
Deno.test('Pending historical refunds are only read and their status refreshed',async()=>{
  const row:any={status:'submitted',stripe_refund_id:'re_old',provider_status:'pending',amount_cents:100,currency:'eur',details:{is_test:true}};
  let updates=0,reads=0;
  const q:any={select:()=>q,eq:()=>q,order:()=>q,limit:async()=>({data:[row]}),update:(v:any)=>({eq:async()=>{updates++;Object.assign(row,v);return {error:null}}})};
  const result=await handleBoxRefund('box_refund_list',{order_id:1},{from:()=>q},()=>({refunds:{retrieve:async()=>{reads++;return {amount:100,currency:'eur',status:'succeeded'}}}}),null,false);
  assert.equal(result.refunds[0].provider_status,'succeeded');assert.equal(reads,1);assert.equal(updates,1);
});
