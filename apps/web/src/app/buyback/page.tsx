import type { Metadata } from "next";
import { BuybackView } from "@/components/data/buyback-view";

export const metadata: Metadata = { title: "Buyback" };

export default function Page() {
  return (
    <div className="container">
      <BuybackView />
    </div>
  );
}
