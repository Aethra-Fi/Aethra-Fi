import type { Metadata } from "next";
import { PositionsView } from "@/components/positions/positions-view";

export const metadata: Metadata = { title: "Positions" };

export default function PositionsPage() {
  return (
    <div className="container">
      <PositionsView />
    </div>
  );
}
