"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { MORE_NAV, PRIMARY_NAV, RESOURCE_NAV } from "./nav";
import { Logo } from "./site-header";

export function SiteFooter() {
  // the landing is a full-height horizontal page with its own bottom bar
  if (usePathname() === "/") return null;
  return (
    <footer className="mt-24 border-t">
      <div className="container grid gap-10 py-12 md:grid-cols-[1.5fr_1fr_1fr_1fr]">
        <div className="space-y-3">
          <Logo />
          <p className="max-w-sm text-sm text-muted">
            The liquidity layer for Robinhood Chain. Adaptive fees, oracle-guarded stock markets and unified
            multi-venue routing.
          </p>
        </div>
        <FooterCol title="Trade" items={PRIMARY_NAV} />
        <FooterCol title="Protocol" items={MORE_NAV.filter((i) => !RESOURCE_NAV.some((r) => r.href === i.href))} />
        <FooterCol title="Resources" items={RESOURCE_NAV} />
      </div>
      <div className="border-t">
        <div className="container flex h-12 items-center justify-between font-mono text-[11px] uppercase tracking-eyebrow text-muted">
          <span>Aethra Fi · {new Date().getFullYear()}</span>
          <span>Built on Robinhood Chain</span>
        </div>
      </div>
    </footer>
  );
}

function FooterCol({ title, items }: { title: string; items: { href: string; label: string }[] }) {
  return (
    <div>
      <p className="eyebrow mb-4">{title}</p>
      <ul className="space-y-2">
        {items.map((i) => (
          <li key={i.href}>
            <Link href={i.href} className="text-sm text-fg-2 transition-ui hover:text-primary-text">
              {i.label}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
