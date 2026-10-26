import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { CreditView } from "@/components/credit/credit-view";
import { FEATURES } from "@/lib/features";

export const metadata: Metadata = { title: "Credit" };

export default function CreditPage() {
  if (!FEATURES.credit) notFound();
  return (
    <div className="container">
      <CreditView />
    </div>
  );
}
