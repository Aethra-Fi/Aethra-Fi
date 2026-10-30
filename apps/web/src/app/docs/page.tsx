import type { Metadata } from "next";
import { DocsView } from "@/components/data/docs-view";

export const metadata: Metadata = {
  title: "Docs",
  description: "How Aethra Fi works: swap routing, pool types, dynamic fees, oracle-guarded stock pools, limit orders and the developer API.",
};

export default function Page() {
  return (
    <div className="container">
      <DocsView />
    </div>
  );
}
