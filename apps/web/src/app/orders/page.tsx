import type { Metadata } from "next";
import { OrdersView } from "@/components/orders/orders-view";

export const metadata: Metadata = { title: "Limit orders" };

export default function OrdersPage() {
  return (
    <div className="container">
      <OrdersView />
    </div>
  );
}
