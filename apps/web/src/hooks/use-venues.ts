"use client";

import { useReadContracts } from "wagmi";
import { ABIS, addressOf } from "@/lib/contracts";
import { CHAIN_ID } from "@/lib/network";

/**
 * Which pool venues are open on the active network. The on-chain gate is the source of truth: a DLMM or DAMM factory
 * can only create pools while the hub lists it as a registrar, so the UI shows a venue exactly when the hub does.
 * Opening a venue later (one hub transaction) shows it here without a redeploy. Closed until the read returns.
 */
export function useOpenVenues(): { dlmm: boolean; damm: boolean; loading: boolean } {
  const hub = addressOf("hub");
  const dlmm = addressOf("dlmmFactory");
  const damm = addressOf("dammFactory");
  const q = useReadContracts({
    contracts: [
      { address: hub!, abi: ABIS.hub, functionName: "isRegistrar", args: [dlmm!], chainId: CHAIN_ID },
      { address: hub!, abi: ABIS.hub, functionName: "isRegistrar", args: [damm!], chainId: CHAIN_ID },
    ],
    query: { enabled: Boolean(hub && dlmm && damm), staleTime: 60_000 },
  });
  return {
    dlmm: q.data?.[0]?.result === true,
    damm: q.data?.[1]?.result === true,
    loading: q.isLoading,
  };
}
