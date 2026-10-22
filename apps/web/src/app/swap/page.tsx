import { Suspense } from "react";
import type { Metadata } from "next";
import { SwapCard } from "@/components/swap/swap-card";

export const metadata: Metadata = { title: "Swap" };

export default function SwapPage() {
  return (
    <div className="container flex justify-center py-12 md:py-20">
      <Suspense>
        <SwapCard />
      </Suspense>
    </div>
  );
}
