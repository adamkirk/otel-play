"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { useBasket } from "@/components/basket";
import { formatPrice } from "@/lib/format";
import type { Order } from "@/lib/types";

export function BasketView({ ordersUrl }: { ordersUrl: string }) {
  const basket = useBasket();
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (basket.items.length === 0) {
    return (
      <p className="text-stone-600">
        Your basket is empty.{" "}
        <Link href="/" className="font-medium text-amber-700 hover:underline">
          Browse products
        </Link>
      </p>
    );
  }

  async function checkout() {
    setSubmitting(true);
    setError(null);

    try {
      // The browser calls orders-api directly (cross-origin, allowed by
      // its CORS config), so there's a real browser → API hop to trace.
      const res = await fetch(`${ordersUrl}/api/orders`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({
          customer_email: email || null,
          items: basket.items.map((i) => ({ product_id: i.productId, quantity: i.quantity })),
        }),
      });
      const body = await res.json();

      if (res.status === 201) {
        basket.clear();
        router.push(`/orders/${(body.data as Order).id}`);
        return;
      }
      if (res.status === 409) {
        setError(`Sorry, we couldn't reserve your items (${body.data.failure_reason}).`);
      } else if (res.status === 422) {
        setError(body.message ?? "Some items in your basket are invalid.");
      } else {
        setError(`Checkout failed (HTTP ${res.status}). Please try again.`);
      }
    } catch {
      setError("Couldn't reach the orders service. Please try again.");
    }
    setSubmitting(false);
  }

  return (
    <div className="max-w-2xl">
      <ul className="divide-y divide-stone-200 rounded-lg border border-stone-200 bg-white">
        {basket.items.map((item) => (
          <li key={item.productId} className="flex items-center justify-between gap-4 p-4">
            <div>
              <p className="font-medium">{item.name}</p>
              <p className="text-sm text-stone-500">{formatPrice(item.pricePence)} each</p>
            </div>
            <div className="flex items-center gap-3">
              <select
                aria-label={`Quantity of ${item.name}`}
                value={item.quantity}
                onChange={(e) => basket.setQuantity(item.productId, Number(e.target.value))}
                className="rounded border border-stone-300 bg-white px-2 py-1"
              >
                {Array.from({ length: 10 }, (_, i) => i + 1).map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
              <span className="w-20 text-right font-medium">
                {formatPrice(item.quantity * item.pricePence)}
              </span>
              <button
                type="button"
                onClick={() => basket.remove(item.productId)}
                className="text-sm text-stone-500 hover:text-red-700"
              >
                Remove
              </button>
            </div>
          </li>
        ))}
      </ul>

      <div className="mt-6 flex flex-col gap-4 rounded-lg border border-stone-200 bg-white p-4">
        <div className="flex justify-between text-lg font-semibold">
          <span>Total</span>
          <span>{formatPrice(basket.totalPence)}</span>
        </div>
        <label className="flex flex-col gap-1 text-sm">
          Email for confirmation (optional)
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="you@example.com"
            className="rounded border border-stone-300 px-3 py-2"
          />
        </label>
        {error && <p className="text-sm text-red-700">{error}</p>}
        <button
          type="button"
          onClick={checkout}
          disabled={submitting}
          className="rounded bg-amber-700 px-4 py-2 font-medium text-white hover:bg-amber-800 disabled:opacity-50"
        >
          {submitting ? "Placing order…" : "Checkout"}
        </button>
      </div>
    </div>
  );
}
