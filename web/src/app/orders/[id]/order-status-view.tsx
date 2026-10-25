"use client";

import { useEffect, useState } from "react";
import { formatPrice } from "@/lib/format";
import type { Order, OrderStatus } from "@/lib/types";

const POLL_MS = 1000;

const statusStyles: Record<OrderStatus, { label: string; className: string }> = {
  pending: { label: "Processing payment…", className: "bg-amber-100 text-amber-900" },
  paid: { label: "Paid", className: "bg-green-100 text-green-900" },
  failed: { label: "Payment failed", className: "bg-red-100 text-red-900" },
  rejected: { label: "Rejected", className: "bg-red-100 text-red-900" },
  cancelled: { label: "Cancelled", className: "bg-stone-200 text-stone-800" },
};

/**
 * Polls orders-api while the order is pending (or a cancellation is in
 * flight) and stops once it reaches a final status.
 */
export function OrderStatusView({ orderId, ordersUrl }: { orderId: string; ordersUrl: string }) {
  const [order, setOrder] = useState<Order | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [cancelRequested, setCancelRequested] = useState(false);

  const settled =
    order !== null &&
    order.status !== "pending" &&
    !(cancelRequested && order.status !== "cancelled");

  useEffect(() => {
    if (settled) return;

    let stopped = false;
    async function poll() {
      try {
        const res = await fetch(`${ordersUrl}/api/orders/${orderId}`, {
          headers: { Accept: "application/json" },
        });
        if (res.status === 404) {
          setError("Order not found.");
          return;
        }
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const body = await res.json();
        if (!stopped) setOrder(body.data);
      } catch {
        if (!stopped) setError("Couldn't reach the orders service. Retrying…");
      }
    }

    poll();
    const timer = setInterval(poll, POLL_MS);
    return () => {
      stopped = true;
      clearInterval(timer);
    };
  }, [orderId, ordersUrl, settled]);

  async function cancel() {
    setCancelRequested(true);
    const res = await fetch(`${ordersUrl}/api/orders/${orderId}/cancel`, {
      method: "POST",
      headers: { Accept: "application/json" },
    });
    if (res.status !== 202) {
      setCancelRequested(false);
      setError("This order can no longer be cancelled.");
    }
  }

  if (!order) {
    return <p className="mt-6 text-stone-500">{error ?? "Loading order…"}</p>;
  }

  const style = statusStyles[order.status];
  const canCancel = (order.status === "pending" || order.status === "paid") && !cancelRequested;

  return (
    <article className="mt-6 max-w-2xl rounded-lg border border-stone-200 bg-white p-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Order #{order.id}</h1>
        <span className={`rounded-full px-3 py-1 text-sm font-medium ${style.className}`}>
          {cancelRequested && order.status !== "cancelled" ? "Cancelling…" : style.label}
        </span>
      </div>
      {order.failure_reason && <p className="mt-2 text-sm text-red-700">{order.failure_reason}</p>}

      <ul className="mt-6 divide-y divide-stone-200">
        {order.items.map((item) => (
          <li key={item.product_id} className="flex justify-between py-2">
            <span>
              {item.quantity} × {item.product_name}
            </span>
            <span>{formatPrice(item.quantity * item.unit_price_pence)}</span>
          </li>
        ))}
      </ul>
      <div className="mt-4 flex justify-between border-t border-stone-200 pt-4 text-lg font-semibold">
        <span>Total</span>
        <span>{formatPrice(order.total_pence)}</span>
      </div>

      {error && <p className="mt-4 text-sm text-red-700">{error}</p>}
      {canCancel && (
        <button
          type="button"
          onClick={cancel}
          className="mt-6 rounded border border-stone-300 px-4 py-2 text-sm hover:border-red-700 hover:text-red-700"
        >
          Cancel order
        </button>
      )}
    </article>
  );
}
