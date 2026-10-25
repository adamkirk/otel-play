import { Suspense } from "react";
import { BasketView } from "@/app/basket/basket-view";
import { runtimeConfig } from "@/lib/config";

export default function BasketPage() {
  return (
    <>
      <h1 className="mb-6 text-2xl font-semibold">Your basket</h1>
      <Suspense fallback={<p className="text-stone-500">Loading basket…</p>}>
        <Basket />
      </Suspense>
    </>
  );
}

async function Basket() {
  const { ordersPublicUrl } = await runtimeConfig();
  return <BasketView ordersUrl={ordersPublicUrl} />;
}
