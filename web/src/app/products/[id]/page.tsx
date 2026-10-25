import Link from "next/link";
import { notFound } from "next/navigation";
import { Suspense } from "react";
import { AddToBasket } from "@/components/add-to-basket";
import { getProduct } from "@/lib/catalogue";
import { formatPrice } from "@/lib/format";

export default function ProductPage({ params }: PageProps<"/products/[id]">) {
  return (
    <>
      <Link href="/" className="text-sm text-stone-500 hover:text-stone-900">
        ← All products
      </Link>
      <Suspense fallback={<p className="mt-6 text-stone-500">Loading product…</p>}>
        <ProductDetail params={params} />
      </Suspense>
    </>
  );
}

async function ProductDetail({ params }: { params: PageProps<"/products/[id]">["params"] }) {
  const { id } = await params;
  const product = await getProduct(id);

  if (!product) notFound();

  return (
    <article className="mt-6 max-w-xl rounded-lg border border-stone-200 bg-white p-6">
      <h1 className="text-2xl font-semibold">{product.name}</h1>
      <p className="mt-2 text-stone-600">{product.description}</p>
      <p className="mt-4 text-xl font-semibold">{formatPrice(product.price_pence)}</p>
      <p className="mb-6 text-sm text-stone-500">{product.stock} in stock</p>
      <AddToBasket product={product} />
    </article>
  );
}
