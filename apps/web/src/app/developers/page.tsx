import type { Metadata } from "next";
import { DevelopersView } from "@/components/data/developers-view";

export const metadata: Metadata = { title: "Developers" };

export default function Page() {
  return (
    <div className="container">
      <DevelopersView />
    </div>
  );
}
