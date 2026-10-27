// Jezik računov, potrdil in dobropisov Stripe je nastavitev stranke.
// Spreminja samo jezik, nikoli plačil, zneskov ali stanja računov.
export async function ensureSlovenianDocuments(client: any, customerId: string): Promise<boolean> {
  const customer = await client.customers.retrieve(customerId);
  if (customer.deleted) return false;
  if (customer.preferred_locales?.[0] === "sl") return false;
  await client.customers.update(customerId, {preferred_locales: ["sl"]});
  return true;
}
