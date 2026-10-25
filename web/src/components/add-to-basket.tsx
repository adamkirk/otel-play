"use client";

import { useState } from "react";
import { useBasket } from "@/components/basket";
import type { Product } from "@/lib/types";

export function AddToBasket({ product }: { product: Product }) {
  const { add } = useBasket();
  const [quantity, setQuantity] = useState(1);
  const [added, setAdded] = useState(false);

  if (product.stock === 0) {
    return <p className="font-medium text-red-700">Out of stock</p>;
  }

  return (
    <div className="flex items-center gap-3">
      <label className="flex items-center gap-2 text-sm">
        Qty
        <select
          value={quantity}
          onChange={(e) => setQuantity(Number(e.target.value))}
          className="rounded border border-stone-300 bg-white px-2 py-1"
        >
          {Array.from({ length: Math.min(product.stock, 10) }, (_, i) => i + 1).map((n) => (
            <option key={n} value={n}>
              {n}
            </option>
          ))}
        </select>
      </label>
      <button
        type="button"
        onClick={() => {
          add({ productId: product.id, name: product.name, pricePence: product.price_pence }, quantity);
          setAdded(true);
        }}
        className="rounded bg-amber-700 px-4 py-2 font-medium text-white hover:bg-amber-800"
      >
        Add to basket
      </button>
      {added && <span className="text-sm text-green-700">Added ✓</span>}
    </div>
  );
}
