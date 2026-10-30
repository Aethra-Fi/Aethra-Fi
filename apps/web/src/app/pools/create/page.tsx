import type { Metadata } from "next";
import { CreatePool } from "@/components/pools/create-pool";

export const metadata: Metadata = { title: "Create pool" };

export default function CreatePoolPage() {
  return (
    <div className="container">
      <CreatePool />
    </div>
  );
}
