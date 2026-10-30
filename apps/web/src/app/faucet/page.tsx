import type { Metadata } from "next";
import { FaucetView } from "@/components/faucet/faucet-view";

export const metadata: Metadata = { title: "Faucet" };

export default function FaucetPage() {
  return (
    <div className="container">
      <FaucetView />
    </div>
  );
}
