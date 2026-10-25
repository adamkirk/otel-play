"use client";

import Link from "next/link";
import { useBasket } from "@/components/basket";

export function Header() {
  const { count } = useBasket();

  return (
    <header className="border-b border-stone-200 bg-white">
      <nav className="mx-auto flex max-w-5xl items-center justify-between px-4 py-4">
        <Link href="/" className="text-lg font-semibold tracking-tight">
          ☕ Tea &amp; Coffee Co.
        </Link>
        <Link
          href="/basket"
          className="rounded-full bg-stone-900 px-4 py-1.5 text-sm font-medium text-white hover:bg-stone-700"
        >
          Basket{count > 0 ? ` (${count})` : ""}
        </Link>
      </nav>
    </header>
  );
}
