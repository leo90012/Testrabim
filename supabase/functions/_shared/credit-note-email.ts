import {validateContractAttachments} from './delivery-contract.ts';

export function creditNoteContent(order:any){
  return {to:String(order.email||''),subject:'Vračilo denarja.',title:'Vračilo denarja.',
    body:'<p style="font-size:14px;line-height:1.6;margin:0 0 16px">Pozdravljeni, danes smo izvedli nakazilo denarja na vaš račun. Nakazilo prejmete v roku 10 dni. V priponki se nahaja dobropis.</p><p style="font-size:14px;line-height:1.6;margin:0">Lep pozdrav,<br>Ekipa Rabimbox</p>'};
}
export function validateCreditNoteAttachments(value:unknown){
  try{return validateContractAttachments(value);}catch(error){throw new Error(String((error as Error).message).replace(/skenov podpisane pogodbe/g,'priponk z dobropisom').replace(/Pogodbo/g,'Dobropis'));}
}
export function creditNoteRequestKey(orderId:number,value:unknown){
  if(typeof value!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value))throw new Error('Neveljavna oznaka pošiljanja. Ponovno odpri osnutek.');
  return `credit-note-${orderId}-${value}`;
}
