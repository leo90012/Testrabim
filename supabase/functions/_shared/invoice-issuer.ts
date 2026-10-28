// Javni podatki izdajatelja, enaki kot na obstoječih Rabimbox računih.
export const INVOICE_ISSUER = {
  name:"Rabim d.o.o.",
  address:"Proletarska cesta 4, 1000 Ljubljana, Slovenija",
  vat:"SI45163260",
  registration:"7155778000",
  iban:"SI56 0201 2026 2090 861",
  bank:"NLB d.d.",
  swift:"LJBASI2X",
  email:"info@rabimbox.si",
  phone:"+386 40 796 040",
};
export const STRIPE_INVOICE_FOOTER = [
  `${INVOICE_ISSUER.name} · ${INVOICE_ISSUER.address}`,
  `ID za DDV: ${INVOICE_ISSUER.vat} · Matična številka: ${INVOICE_ISSUER.registration}`,
  `TRR: ${INVOICE_ISSUER.iban} (${INVOICE_ISSUER.bank}) · SWIFT: ${INVOICE_ISSUER.swift}`,
  `${INVOICE_ISSUER.email} · ${INVOICE_ISSUER.phone}`,
].join("\n");
