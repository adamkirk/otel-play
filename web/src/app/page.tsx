import Link from "next/link";
import { Suspense } from "react";
import { listProducts } from "@/lib/catalogue";
import { formatPrice } from "@/lib/format";

export default function Home() {
  return (
    <>
      <h1 className="mb-6 text-2xl font-semibold">Products</h1>
      <Suspense fallback={<p className="text-stone-500">Loading products…</p>}>
        <ProductGrid />
      </Suspense>
    </>
  );
}

async function ProductGrid() {
  const products = await listProducts();

  return (
    <ul className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {products.map((product) => (
        <li key={product.id}>
          <Link
            href={`/products/${product.id}`}
            className="block h-full rounded-lg border border-stone-200 bg-white p-5 transition hover:border-amber-600 hover:shadow-sm"
          >
            <h2 className="font-medium">{product.name}</h2>
            <p className="mt-1 text-sm text-stone-600">{product.description}</p>
            <div className="mt-4 flex items-baseline justify-between">
              <span className="text-lg font-semibold">{formatPrice(product.price_pence)}</span>
              <span className={product.stock > 0 ? "text-sm text-stone-500" : "text-sm text-red-700"}>
                {product.stock > 0 ? `${product.stock} in stock` : "Out of stock"}
              </span>
            </div>
          </Link>
        </li>
      ))}
    </ul>
  );
}
