"use client";

import { NETWORK_LABEL, NETWORK, SELECTABLE_NETWORKS, isDeployed, isSelectable, setNetwork, useNetwork } from "@/lib/network";

/** Shown when the active network has no Aethra contracts (for example a mainnet build before launch). */
export function NetworkNotice() {
  const network = useNetwork();
  if (isDeployed(network)) return null;
  const fallback = SELECTABLE_NETWORKS.find((n) => n !== NETWORK && isSelectable(n));
  return (
    <div role="status" className="border-b bg-warning-soft">
      <div className="container flex flex-wrap items-center gap-x-3 gap-y-1 py-2 font-mono text-[11px] uppercase tracking-eyebrow text-warning">
        <span>Aethra Fi is not deployed on {NETWORK_LABEL[network]} yet.</span>
        {fallback && (
          <button type="button" onClick={() => setNetwork(fallback)} className="underline underline-offset-2 hover:text-fg">
            Switch to {NETWORK_LABEL[fallback]}
          </button>
        )}
      </div>
    </div>
  );
}
