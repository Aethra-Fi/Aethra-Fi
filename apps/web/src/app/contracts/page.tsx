import type { Metadata } from "next";
import { ContractsView } from "@/components/data/contracts-view";

export const metadata: Metadata = { title: "Contracts" };

export default function Page() {
  return (
    <div className="container">
      <ContractsView />
    </div>
  );
}
