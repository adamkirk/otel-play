"use client";

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { BasketItem } from "@/lib/types";

const STORAGE_KEY = "otel-play-basket";

type Basket = {
  items: BasketItem[];
  count: number;
  totalPence: number;
  add: (item: Omit<BasketItem, "quantity">, quantity: number) => void;
  setQuantity: (productId: string, quantity: number) => void;
  remove: (productId: string) => void;
  clear: () => void;
};

const BasketContext = createContext<Basket | null>(null);

function load(): BasketItem[] {
  try {
    return JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? "[]");
  } catch {
    return [];
  }
}

function save(items: BasketItem[]) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(items));
  } catch {
    // Storage blocked (private mode etc.): the basket just won't persist.
  }
}

/** Basket state, kept in localStorage so it survives page reloads. */
export function BasketProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<BasketItem[]>([]);
  const [loaded, setLoaded] = useState(false);

  // Read storage after hydration so server and client render the same HTML.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- one-off sync from localStorage
    setItems(load());
    setLoaded(true);
  }, []);

  useEffect(() => {
    if (loaded) save(items);
  }, [items, loaded]);

  const basket: Basket = {
    items,
    count: items.reduce((n, i) => n + i.quantity, 0),
    totalPence: items.reduce((n, i) => n + i.quantity * i.pricePence, 0),
    add: (item, quantity) =>
      setItems((current) => {
        const existing = current.find((i) => i.productId === item.productId);
        if (!existing) return [...current, { ...item, quantity }];
        return current.map((i) =>
          i.productId === item.productId ? { ...i, quantity: Math.min(i.quantity + quantity, 10) } : i,
        );
      }),
    setQuantity: (productId, quantity) =>
      setItems((current) =>
        current.map((i) => (i.productId === productId ? { ...i, quantity } : i)),
      ),
    remove: (productId) => setItems((current) => current.filter((i) => i.productId !== productId)),
    clear: () => setItems([]),
  };

  return <BasketContext.Provider value={basket}>{children}</BasketContext.Provider>;
}

export function useBasket(): Basket {
  const basket = useContext(BasketContext);
  if (!basket) throw new Error("useBasket must be used inside <BasketProvider>");
  return basket;
}
