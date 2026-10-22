import { Suspense } from "react";
import type { Metadata } from "next";
import { PoolsExplorer } from "@/components/pools/pools-explorer";

export const metadata: Metadata = { title: "Pools" };

export default function PoolsPage() {
  return (
    <div className="container">
      <Suspense>
        <PoolsExplorer />
      </Suspense>
    </div>
  );
}
