import Link from "next/link";
import { Suspense } from "react";
import { OrderStatusView } from "@/app/orders/[id]/order-status-view";
import { runtimeConfig } from "@/lib/config";

export default function OrderPage({ params }: PageProps<"/orders/[id]">) {
  return (
    <>
      <Link href="/" className="text-sm text-stone-500 hover:text-stone-900">
        ← Continue shopping
      </Link>
      <Suspense fallback={<p className="mt-6 text-stone-500">Loading order…</p>}>
        <OrderStatus params={params} />
      </Suspense>
    </>
  );
}

async function OrderStatus({ params }: { params: PageProps<"/orders/[id]">["params"] }) {
  const [{ id }, { ordersPublicUrl }] = await Promise.all([params, runtimeConfig()]);
  return <OrderStatusView orderId={id} ordersUrl={ordersPublicUrl} />;
}
