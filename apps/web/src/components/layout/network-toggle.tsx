"use client";

import { useAccount, useSwitchChain } from "wagmi";
import { chainsByNetwork } from "@aethrafi/sdk";
import { NETWORK_LABEL, SELECTABLE_NETWORKS, isSelectable, setNetwork, useNetwork, type NetworkName } from "@/lib/network";
import { cn } from "@/lib/utils";

/** Testnet / Mainnet switch. A network without published contracts stays visible but disabled ("soon"). */
export function NetworkToggle({ className }: { className?: string }) {
  const active = useNetwork();
  const { isConnected } = useAccount();
  const { switchChainAsync } = useSwitchChain();

  if (SELECTABLE_NETWORKS.length < 2) {
    return (
      <span className={cn("items-center border px-2 py-1 font-mono text-[11px] uppercase tracking-eyebrow text-muted", className)}>
        {NETWORK_LABEL[active]}
      </span>
    );
  }

  function choose(network: NetworkName) {
    if (network === active || !setNetwork(network)) return;
    // keep the wallet on the same chain as the app; if the wallet refuses, the next transaction asks again
    if (isConnected) void switchChainAsync({ chainId: chainsByNetwork[network].id }).catch(() => {});
  }

  return (
    <div role="group" aria-label="Network" className={cn("items-center border p-0.5", className)}>
      {SELECTABLE_NETWORKS.map((n) => {
        const available = isSelectable(n);
        return (
          <button
            key={n}
            type="button"
            disabled={!available}
            aria-pressed={n === active}
            title={available ? undefined : `${NETWORK_LABEL[n]} is not live yet`}
            onClick={() => choose(n)}
            className={cn(
              "fx-cyber px-2.5 py-1 font-mono text-[11px] uppercase tracking-eyebrow transition-ui",
              n === active ? "bg-primary-soft text-primary-text" : "text-muted hover:text-fg",
              !available && "cursor-not-allowed opacity-50 hover:text-muted",
            )}
          >
            {NETWORK_LABEL[n]}
            {!available && <span className="ml-1 normal-case tracking-normal">· soon</span>}
          </button>
        );
      })}
    </div>
  );
}
