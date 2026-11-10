// Pretekla evidenca ostane berljiva. Vračila denarja se sedaj uredijo ročno.
async function checked(p:any):Promise<any>{const r=await p;if(r.error)throw r.error;return r.data;}
export async function handleBoxRefund(action:string,body:any,sb:any,clientFor:(test:boolean)=>any,_actorId:string|null,_primaryLive:boolean){
  if(action!=='box_refund_list')throw new Error('Vračilo denarja uredite ročno. V panelu vrnite boxe v zalogo, nato pošljite dobropis.');
  const order=Number(body.order_id);
  if(!Number.isSafeInteger(order)||order<=0)throw new Error('Naročilo ni veljavno.');
  const refunds=await checked(sb.from('rb_box_refunds').select('*').eq('order_id',order).order('created_at',{ascending:false}).limit(30));
  for(const row of refunds){
    if(row.status!=='submitted'||!row.stripe_refund_id||['succeeded','failed','canceled'].includes(row.provider_status))continue;
    try{
      const remote=await clientFor(row.details.is_test===true).refunds.retrieve(row.stripe_refund_id);
      if(remote.amount!==row.amount_cents||remote.currency!==row.currency)throw new Error('Znesek vračila se ne ujema.');
      if(remote.status!==row.provider_status){
        const changes={provider_status:remote.status,error:remote.status==='failed'?'Stripe je vračilo zavrnil. Potreben je ročni pregled v Stripe.':null};
        await checked(sb.from('rb_box_refunds').update(changes).eq('id',row.id));Object.assign(row,changes);
      }
    }catch{row.status_note='Trenutnega stanja Stripe ni mogoče preveriti.';}
  }
  return {refunds};
}
