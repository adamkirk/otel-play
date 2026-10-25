import { runtimeConfig } from "@/lib/config";
import { logger } from "@/lib/logger";
import type { Product } from "@/lib/types";

/**
 * Server-side calls to catalogue-api. Results are deliberately not cached,
 * so every page view shows live stock and makes a real request.
 */
async function catalogueFetch(path: string): Promise<Response> {
  const { catalogueUrl } = await runtimeConfig();
  const started = performance.now();

  const res = await fetch(`${catalogueUrl}${path}`, { headers: { Accept: "application/json" } });

  logger.info("catalogue request", {
    path,
    status: res.status,
    duration_ms: Math.round(performance.now() - started),
  });
  return res;
}

export async function listProducts(): Promise<Product[]> {
  const res = await catalogueFetch("/products");
  if (!res.ok) {
    throw new Error(`catalogue-api returned ${res.status} listing products`);
  }
  return res.json();
}

/** Returns null when the product does not exist. */
export async function getProduct(id: string): Promise<Product | null> {
  const res = await catalogueFetch(`/products/${encodeURIComponent(id)}`);
  if (res.status === 404) {
    return null;
  }
  if (!res.ok) {
    throw new Error(`catalogue-api returned ${res.status} for product ${id}`);
  }
  return res.json();
}
