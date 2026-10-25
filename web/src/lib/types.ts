export type Product = {
  id: string;
  name: string;
  description: string;
  price_pence: number;
  stock: number;
};

export type OrderStatus = "pending" | "paid" | "failed" | "rejected" | "cancelled";

export type Order = {
  id: number;
  status: OrderStatus;
  customer_email: string | null;
  total_pence: number;
  failure_reason: string | null;
  paid_at: string | null;
  created_at: string;
  items: {
    product_id: string;
    product_name: string;
    quantity: number;
    unit_price_pence: number;
  }[];
};

export type BasketItem = {
  productId: string;
  name: string;
  pricePence: number;
  quantity: number;
};
