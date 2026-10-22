import type { Metadata } from "next";
import { CreditView } from "@/components/credit/credit-view";

export const metadata: Metadata = { title: "Credit" };

export default function CreditPage() {
  return (
    <div className="container">
      <CreditView />
    </div>
  );
}
