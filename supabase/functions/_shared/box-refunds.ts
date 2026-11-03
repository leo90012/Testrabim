import {ensureSlovenianDocuments} from './stripe-language.ts';

export function returnBoxIds(value:unknown):number[]{
  if(!Array.isArray(value)||!value.length||value.length>5000||value.some(n=>!Number.isSafeInteger(n)||n<=0)||new Set(value).size!==value.length)throw new Error('Izberite veljavne boxe.');
  return [...value].sort((a,b)=>a-b);
}
const uuid=(v:unknown)=>{if(typeof v!=='string'||! /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v))throw new Error('Ključ vračila ni veljaven.');return v;};
const orderId=(v:unknown)=>{if(!Number.isSafeInteger(v)||Number(v)<=0)throw new Error('Naročilo ni veljavno.');return Number(v);};
const id=(v:any):string|null=>typeof v==='string'?v:v?.id||null;
async function checked(p:any):Promise<any>{const r=await p;if(r.error)throw r.error;return r.data;}
export function creditNoteParams(q:any,operationId?:string){
  const params:any={invoice:q.stripe_invoice_id,amount:q.amount_cents,refund_amount:q.amount_cents,reason:'order_change',email_type:'none',
    memo:`Sorazmerno vračilo za ${q.box_count} boxov: ${q.unused_days} neizkoriščenih dni 30-dnevnega obdobja ${q.period_start}–${q.period_end}.`};
  if(operationId)params.metadata={rabimbox_box_refund:operationId,rabimbox_order:String(q.order_id)};
  return params;
}
export async function validateCardRefund(q:any,client:any,expectedLive:boolean){
  const inv=await client.invoices.retrieve(q.stripe_invoice_id);
  if(inv.status!=='paid'||inv.amount_remaining!==0||inv.currency!==q.currency||inv.amount_paid<q.amount_cents||inv.livemode!==expectedLive)throw new Error('Plačilo, valuta ali način Stripe se ne ujemajo z vračilom.');
  if(q.stripe_customer_id&&id(inv.customer)!==q.stripe_customer_id)throw new Error('Stripe račun ne pripada stranki tega naročila.');
  const preview=await client.creditNotes.preview(creditNoteParams(q));
  if(preview.total!==q.amount_cents||preview.post_payment_amount!==q.amount_cents||preview.pre_payment_amount!==0||preview.currency!==q.currency)throw new Error('Stripe predogled se ne ujema z zneskom vračila.');
  return preview;
}
async function existingCreditNote(client:any,row:any){
  // Iskanje po trajni evidenci prepreči podvojitev tudi po izteku Stripe ključa (24 ur).
  if(row.stripe_credit_note_id)return await client.creditNotes.retrieve(row.stripe_credit_note_id);
  let after:string|undefined;
  for(let page=0;page<10;page++){
    const list=await client.creditNotes.list({invoice:row.details.stripe_invoice_id,limit:100,...(after?{starting_after:after}:{})});
    const found=list.data.find((c:any)=>c.metadata?.rabimbox_box_refund===row.id);if(found)return found;
    if(!list.has_more)return null;after=list.data.at(-1)?.id;
  }
  throw new Error('Zgodovina Stripe dobropisov zahteva ročni pregled. Vračilo ni bilo ponovljeno.');
}
export async function processBoxRefund(sb:any,row:any,clientFor:(test:boolean)=>any,primaryLive:boolean){
  const token=crypto.randomUUID();
  row=await checked(sb.rpc('rb_claim_box_refund',{p_id:row.id,p_token:token}));
  if(row.status!=='prepared')return row;
  try{
    let values:any={status:row.mode==='manual'?'manual':'completed',completed_at:new Date().toISOString(),error:null,lease_token:null,lease_until:null};
    if(row.mode==='stripe'){
      const q=row.details,client=clientFor(q.is_test===true);
      let cn=await existingCreditNote(client,row);
      if(!cn){
        await validateCardRefund(q,client,q.is_test===true?false:primaryLive);
        if(q.stripe_customer_id)await ensureSlovenianDocuments(client,q.stripe_customer_id);
        cn=await client.creditNotes.create(creditNoteParams(q,row.id),{idempotencyKey:'rb-box-refund-'+row.id});
      }
      if(cn.status!=='issued'||cn.total!==row.amount_cents||id(cn.invoice)!==q.stripe_invoice_id||cn.currency!==row.currency||cn.livemode!==(q.is_test===true?false:primaryLive))throw new Error('Stripe dobropis se ne ujema z evidenco vračila.');
      const refundId=id(cn.refund)||id(cn.refunds?.[0]?.refund);
      const refund=refundId?await client.refunds.retrieve(refundId):null;
      if(refund&&(refund.amount!==row.amount_cents||refund.currency!==row.currency))throw new Error('Stripe vračilo se ne ujema z dobropisom.');
      values={...values,status:'submitted',stripe_credit_note_id:cn.id,credit_note_number:cn.number||null,stripe_refund_id:refundId,provider_status:refund?.status||'unknown',pdf_url:cn.pdf||null,
        error:refund?.status==='failed'?'Stripe je vračilo zavrnil. Potreben je pregled v Stripe.':refund?null:'Dobropis je izdan; stanje vračila preverite v Stripe.'};
    }
    const saved=await checked(sb.from('rb_box_refunds').update(values).eq('id',row.id).eq('lease_token',token).select('*').maybeSingle());
    if(!saved)throw new Error('Vračilo obdeluje drug postopek. Osvežite podatke.');
    return saved;
  }catch(e){
    await sb.from('rb_box_refunds').update({error:String((e as Error).message||e).slice(0,1000),lease_token:null,lease_until:null}).eq('id',row.id).eq('lease_token',token);
    throw new Error('Boxi so vrnjeni v zalogo, vračilo plačila pa še ni zaključeno: '+String((e as Error).message||e));
  }
}
export async function handleBoxRefund(action:string,body:any,sb:any,clientFor:(test:boolean)=>any,actorId:string|null,primaryLive:boolean){
  const order=orderId(body.order_id);
  if(action==='box_refund_list'){
    const refunds=await checked(sb.from('rb_box_refunds').select('*').eq('order_id',order).order('created_at',{ascending:false}).limit(30));
    for(const row of refunds){
      if(row.status!=='submitted'||!row.stripe_refund_id||['succeeded','failed','canceled'].includes(row.provider_status))continue;
      try{
        const remote=await clientFor(row.details.is_test===true).refunds.retrieve(row.stripe_refund_id);
        if(remote.amount!==row.amount_cents||remote.currency!==row.currency)throw new Error('Znesek vračila se ne ujema.');
        if(remote.status!==row.provider_status){
          const changes={provider_status:remote.status,error:remote.status==='failed'?'Stripe je vračilo zavrnil. Potreben je pregled v Stripe.':null};
          await checked(sb.from('rb_box_refunds').update(changes).eq('id',row.id));Object.assign(row,changes);
        }
      }catch{row.status_note='Trenutnega stanja Stripe ni mogoče preveriti.';}
    }
    return {refunds};
  }
  if(action==='box_refund_retry'){
    if(body.confirmed!==true)throw new Error('Potrdite ponovitev vračila.');
    const row=await checked(sb.from('rb_box_refunds').select('*').eq('id',uuid(body.refund_id)).eq('order_id',order).single());
    return {ok:true,refund:await processBoxRefund(sb,row,clientFor,primaryLive)};
  }
  const boxes=returnBoxIds(body.box_ids);
  if(action==='box_refund_preview'){
    const q=await checked(sb.rpc('rb_box_return_quote',{p_order:order,p_boxes:boxes}));
    if(q.mode==='stripe')await validateCardRefund(q,clientFor(q.is_test===true),q.is_test===true?false:primaryLive);
    return {quote:q};
  }
  if(action!=='box_refund')throw new Error('Neveljavno dejanje vračila.');
  if(body.confirmed!==true||!Number.isSafeInteger(body.expected_amount)||body.expected_amount<0)throw new Error('Potrdite predogled vračila.');
  const key=uuid(body.request_key);
  let row=await checked(sb.from('rb_box_refunds').select('*').eq('id',key).maybeSingle());
  if(row){
    if(row.order_id!==order||JSON.stringify(row.box_ids)!==JSON.stringify(boxes))throw new Error('Ključ vračila je že uporabljen za drugo izbiro.');
  }else{
    const q=await checked(sb.rpc('rb_box_return_quote',{p_order:order,p_boxes:boxes}));
    if(q.amount_cents!==body.expected_amount)throw new Error('Znesek se je spremenil. Ponovno odprite predogled.');
    if(q.mode==='stripe')await validateCardRefund(q,clientFor(q.is_test===true),q.is_test===true?false:primaryLive);
    row=await checked(sb.rpc('rb_prepare_box_refund',{p_order:order,p_boxes:boxes,p_key:key,p_expected:body.expected_amount,p_actor:actorId}));
  }
  return {ok:true,refund:await processBoxRefund(sb,row,clientFor,primaryLive)};
}
