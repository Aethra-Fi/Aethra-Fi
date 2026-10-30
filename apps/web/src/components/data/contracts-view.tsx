"use client";

import * as React from "react";
import { Check, Copy } from "lucide-react";
import { AddressLink, PageHeader } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { contractGroups } from "@/lib/contracts";
import { CHAIN, DEPLOYMENT, NETWORK, NETWORK_LABEL } from "@/lib/network";

function CopyButton({ value }: { value: string }) {
  const [done, setDone] = React.useState(false);
  return (
    <button
      aria-label="Copy address"
      onClick={() => {
        void navigator.clipboard?.writeText(value).then(() => {
          setDone(true);
          setTimeout(() => setDone(false), 1200);
        });
      }}
      className="text-muted transition-ui hover:text-primary-text"
    >
      {done ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
    </button>
  );
}

export function ContractsView() {
  const groups = contractGroups(DEPLOYMENT);
  return (
    <>
      <PageHeader
        eyebrow="Contracts"
        title="Protocol contracts"
        description={`Every Aethra contract on ${CHAIN.name} (chain ${CHAIN.id}). Core contracts are UUPS upgradeable proxies; the addresses below are the stable proxy addresses.`}
        actions={<Badge variant="outline">{NETWORK_LABEL[NETWORK]}</Badge>}
      />
      <div className="mt-8 space-y-10">
        {groups.map((g) => (
          <section key={g.category} className="space-y-3">
            <p className="eyebrow">{g.category}</p>
            <div className="hairline-grid grid border">
              {g.entries.map((e) => (
                <div key={e.key} className="grid gap-2 bg-surface px-4 py-3 md:grid-cols-[220px_1fr_auto] md:items-center">
                  <span className="flex items-center gap-2">
                    <span className="font-medium">{e.label}</span>
                    {e.external && <Badge variant="neutral">External</Badge>}
                  </span>
                  <span className="text-sm text-muted">{e.description}</span>
                  <span className="flex items-center gap-2 text-sm">
                    {e.address ? (
                      <>
                        <AddressLink address={e.address} label={e.address} className="text-xs" />
                        <CopyButton value={e.address} />
                      </>
                    ) : (
                      <span className="font-mono text-xs text-muted">Not deployed</span>
                    )}
                  </span>
                </div>
              ))}
            </div>
          </section>
        ))}
        <section className="space-y-3">
          <p className="eyebrow">Admin</p>
          <div className="border bg-surface px-4 py-3 text-sm">
            Owner and upgrade authority: <AddressLink address={DEPLOYMENT.deployer} label={DEPLOYMENT.deployer} className="text-xs" />
          </div>
        </section>
      </div>
    </>
  );
}
