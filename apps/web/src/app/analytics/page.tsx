import type { Metadata } from "next";
import { AnalyticsView } from "@/components/data/analytics-view";

export const metadata: Metadata = { title: "Analytics" };

export default function Page() {
  return (
    <div className="container">
      <AnalyticsView />
    </div>
  );
}
