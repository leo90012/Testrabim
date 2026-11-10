import assert from 'node:assert/strict';
import {creditNoteContent,validateCreditNoteAttachments,creditNoteRequestKey} from './credit-note-email.ts';
import {deliveryRequestKey} from './delivery-contract.ts';
const uuid='eb458c86-a7eb-41db-a23d-f802d29f9c5e';
Deno.test('Credit-note copy and recipient match the requested manual message',()=>{
  const m=creditNoteContent({email:'customer@example.test'});assert.equal(m.to,'customer@example.test');assert.equal(m.subject,'Vračilo denarja.');
  assert.match(m.body,/danes smo izvedli nakazilo denarja na vaš račun/);assert.match(m.body,/v roku 10 dni/);assert.match(m.body,/V priponki se nahaja dobropis/);assert.match(m.body,/Lep pozdrav/);
});
Deno.test('Credit-note attachment is mandatory and must be a real allowed file',()=>{
  assert.throws(()=>validateCreditNoteAttachments([]),/dobropisom/);assert.throws(()=>validateCreditNoteAttachments([{filename:'x.pdf',content:btoa('not a PDF')}]),/Dobropis/);
  assert.throws(()=>validateCreditNoteAttachments([{filename:'../x.pdf',content:btoa('%PDF-1.7\n')}]),/Ime/);
  assert.equal(validateCreditNoteAttachments([{filename:'Dobropis.pdf',content:btoa('%PDF-1.7\n')}])[0].filename,'Dobropis.pdf');
});
Deno.test('Manual credit-note retries are stable and independent of delivery-contract mail',()=>{
  assert.equal(creditNoteRequestKey(1,uuid),creditNoteRequestKey(1,uuid));assert.notEqual(creditNoteRequestKey(1,uuid),deliveryRequestKey(1,uuid));assert.throws(()=>creditNoteRequestKey(1,'bad'));
});
