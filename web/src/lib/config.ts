import { connection } from "next/server";

export type RuntimeConfig = {
  /** In-cluster URL for server-side calls to catalogue-api. */
  catalogueUrl: string;
  /** URL the browser uses to call orders-api. */
  ordersPublicUrl: string;
};

/**
 * Reads config from the environment at request time.
 *
 * The `connection()` call matters: without it, Next would read these during
 * `next build` prerendering and bake the build machine's values into the
 * page. Waiting for a real request means one image works anywhere, with the
 * URLs set by the Helm chart.
 */
export async function runtimeConfig(): Promise<RuntimeConfig> {
  await connection();

  return {
    catalogueUrl: process.env.CATALOGUE_URL ?? "http://catalogue-api",
    ordersPublicUrl: process.env.ORDERS_PUBLIC_URL ?? "http://orders.localhost",
  };
}
