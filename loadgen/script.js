// Traffic generator for the otel-play shop.
//
//   k6 run loadgen/script.js                           # defaults: 5 shoppers for 5m
//   VUS=20 DURATION=30m k6 run loadgen/script.js
//
// Three scenarios run side by side:
//   shoppers  - browse the storefront, check out, follow the order through
//   chaos     - steady calls to catalogue-api's /chaos (latency + 500s)
//   warehouse - restocks anything running low, so long runs don't sell out
import http from "k6/http";
import { check, group, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

const SHOP_URL = __ENV.SHOP_URL || "http://shop.localhost";
const ORDERS_URL = __ENV.ORDERS_URL || "http://orders.localhost";
const CATALOGUE_URL = __ENV.CATALOGUE_URL || "http://catalogue.localhost";
const VUS = Number(__ENV.VUS || 5);
const DURATION = __ENV.DURATION || "5m";

const CHECKOUT_RATE = 0.6; // share of shopper visits that place an order
const CANCEL_RATE = 0.1; // share of placed orders that get cancelled
const INVALID_ORDER_RATE = 0.03; // share of checkouts with an unknown product (422)
const RESTOCK_BELOW = 20;
const RESTOCK_QUANTITY = 50;

const ordersPlaced = new Counter("orders_placed");
const ordersRejected = new Counter("orders_rejected");
const orderOutcomes = new Counter("order_outcomes");
const timeToSettle = new Trend("order_time_to_settle", true);

// Business outcomes like "out of stock" (409) or "invalid basket" (422)
// aren't failures of the system, so they're excluded from http_req_failed.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 299 }, 404, 409, 422));

export const options = {
  scenarios: {
    shoppers: { executor: "constant-vus", exec: "shopper", vus: VUS, duration: DURATION },
    chaos: {
      executor: "constant-arrival-rate",
      exec: "chaos",
      rate: 1,
      timeUnit: "5s",
      duration: DURATION,
      preAllocatedVUs: 2,
    },
    warehouse: {
      executor: "constant-arrival-rate",
      exec: "warehouse",
      rate: 1,
      timeUnit: "15s",
      duration: DURATION,
      preAllocatedVUs: 1,
    },
  },
  thresholds: {
    "http_req_failed{scenario:shoppers}": ["rate<0.05"],
    "checks{scenario:shoppers}": ["rate>0.95"],
  },
};

const json = { headers: { "Content-Type": "application/json", Accept: "application/json" } };

export function setup() {
  const res = http.get(`${CATALOGUE_URL}/products`);
  if (res.status !== 200) {
    throw new Error(`can't list products from ${CATALOGUE_URL} (HTTP ${res.status}); is the shop up?`);
  }
  return { productIds: res.json().map((p) => p.id) };
}

export function shopper({ productIds }) {
  group("browse", () => {
    const home = http.get(`${SHOP_URL}/`, { tags: { name: "shop /" } });
    check(home, { "home page 200": (r) => r.status === 200 });
    think(0.5, 2);

    for (const id of pickSome(productIds, randomInt(1, 3))) {
      const page = http.get(`${SHOP_URL}/products/${id}`, { tags: { name: "shop /products/[id]" } });
      check(page, { "product page 200": (r) => r.status === 200 });
      think(0.5, 2);
    }
  });

  if (Math.random() < CHECKOUT_RATE) {
    group("checkout", () => checkout(productIds));
  }

  think(1, 3);
}

function checkout(productIds) {
  const items = pickSome(productIds, randomInt(1, 3)).map((id) => ({
    product_id: id,
    quantity: randomInt(1, 2),
  }));
  if (Math.random() < INVALID_ORDER_RATE) {
    items.push({ product_id: "does-not-exist", quantity: 1 });
  }

  const created = http.post(
    `${ORDERS_URL}/api/orders`,
    JSON.stringify({ customer_email: Math.random() < 0.7 ? `shopper${__VU}@example.com` : null, items }),
    { ...json, tags: { name: "POST /api/orders" } },
  );
  check(created, { "order accepted, rejected or invalid": (r) => [201, 409, 422].includes(r.status) });

  if (created.status === 409) ordersRejected.add(1);
  if (created.status !== 201) return;
  ordersPlaced.add(1);

  const order = created.json("data");
  const started = Date.now();

  if (Math.random() < CANCEL_RATE) {
    think(0.2, 1);
    const cancelled = http.post(`${ORDERS_URL}/api/orders/${order.id}/cancel`, null, {
      ...json,
      tags: { name: "POST /api/orders/[id]/cancel" },
    });
    check(cancelled, { "cancel accepted or too late": (r) => [202, 409].includes(r.status) });
  }

  // Poll like the order status page does, until the worker settles it.
  for (let i = 0; i < 30; i++) {
    sleep(1);
    const res = http.get(`${ORDERS_URL}/api/orders/${order.id}`, {
      ...json,
      tags: { name: "GET /api/orders/[id]" },
    });
    const status = res.status === 200 ? res.json("data.status") : null;
    if (status && status !== "pending") {
      orderOutcomes.add(1, { status });
      timeToSettle.add(Date.now() - started);
      return;
    }
  }
  orderOutcomes.add(1, { status: "timed_out" });
}

export function chaos() {
  http.get(`${CATALOGUE_URL}/chaos`, {
    tags: { name: "GET /chaos" },
    // 500s are the point of this endpoint.
    responseCallback: http.expectedStatuses(200, 500),
  });
}

export function warehouse() {
  const res = http.get(`${CATALOGUE_URL}/products`, { tags: { name: "GET /products" } });
  if (res.status !== 200) return;

  for (const product of res.json()) {
    if (product.stock >= RESTOCK_BELOW) continue;
    http.post(
      `${CATALOGUE_URL}/stock/restock`,
      JSON.stringify({ product_id: product.id, quantity: RESTOCK_QUANTITY }),
      { ...json, tags: { name: "POST /stock/restock" } },
    );
  }
}

function randomInt(min, max) {
  return min + Math.floor(Math.random() * (max - min + 1));
}

function think(minSeconds, maxSeconds) {
  sleep(minSeconds + Math.random() * (maxSeconds - minSeconds));
}

function pickSome(list, n) {
  return [...list].sort(() => Math.random() - 0.5).slice(0, n);
}
