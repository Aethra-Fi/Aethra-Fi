import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { BuybackView } from "@/components/data/buyback-view";
import { FEATURES } from "@/lib/features";

export const metadata: Metadata = { title: "Buyback" };

export default function Page() {
  if (!FEATURES.buyback) notFound();
  return (
    <div className="container">
      <BuybackView />
    </div>
  );
}
