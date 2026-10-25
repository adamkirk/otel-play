const gbp = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

export function formatPrice(pence: number): string {
  return gbp.format(pence / 100);
}
