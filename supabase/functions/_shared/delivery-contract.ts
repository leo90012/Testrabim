export const CONTRACT_MAX_BYTES = 10 * 1024 * 1024;
export type ContractAttachment = {filename:string;content:string};

export function deliveryContractContent(order:any){
  return {
    to:String(order.email||""),subject:"Boxi so pri vas – Rabimbox",title:"Boxi so pri vas",
    body:`<p style="font-size:14px;line-height:1.6;margin:0 0 16px">Pozdravljeni, boxe smo dostavili na vaš naslov. V priponki se nahaja sken pogodbe o sodelovanju.</p>
      <p style="font-size:14px;line-height:1.6;margin:0">Želimo vam prijetno uporabo!<br>Ekipa Rabimbox</p>`
  };
}

export function validateContractAttachments(value:unknown):ContractAttachment[]{
  if(!Array.isArray(value)||value.length<1||value.length>5)throw new Error("Dodaj od 1 do 5 skenov podpisane pogodbe.");
  let total=0;
  return value.map(item=>{
    const name=String(item?.filename||"").trim();
    if(!name||name.length>160||/[\x00-\x1f\x7f/\\]/.test(name))throw new Error("Ime priponke ni veljavno.");
    const content=item?.content;
    if(typeof content!=="string"||content.length>Math.ceil(CONTRACT_MAX_BYTES/3)*4||!content.length||content.length%4!==0||!/^[A-Za-z0-9+/]*={0,2}$/.test(content))throw new Error("Vsebina priponke ni veljavna ali je prevelika.");
    let bytes:string;try{bytes=atob(content);}catch{throw new Error("Vsebina priponke ni veljavna.");}
    total+=bytes.length;if(!bytes.length||total>CONTRACT_MAX_BYTES)throw new Error("Skupna velikost priponk je lahko največ 10 MB.");
    const extension=name.split('.').pop()?.toLowerCase();
    const pdf=extension==="pdf"&&bytes.slice(0,1024).includes("%PDF-");
    const jpeg=["jpg","jpeg"].includes(extension||"")&&bytes.charCodeAt(0)===255&&bytes.charCodeAt(1)===216&&bytes.charCodeAt(2)===255;
    const png=extension==="png"&&bytes.slice(0,8)==="\x89PNG\r\n\x1a\n";
    if(!pdf&&!jpeg&&!png)throw new Error("Pogodbo dodaj kot veljaven PDF, JPG ali PNG.");
    return {filename:name,content};
  });
}

export function deliveryRequestKey(orderId:number,value:unknown){
  if(typeof value!=="string"||!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value))throw new Error("Neveljavna oznaka pošiljanja. Ponovno odpri osnutek.");
  return `delivery-contract-${orderId}-${value}`;
}
