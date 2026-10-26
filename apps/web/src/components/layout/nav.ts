import { FEATURES } from "@/lib/features";

export interface NavItem {
  href: string;
  label: string;
  description?: string;
}

const ALL_PRIMARY: (NavItem & { hidden?: boolean })[] = [
  { href: "/swap", label: "Swap" },
  { href: "/pools", label: "Pools" },
  { href: "/positions", label: "Positions" },
  { href: "/launch", label: "Launch", hidden: !FEATURES.launchpad },
  { href: "/credit", label: "Credit", hidden: !FEATURES.credit },
  { href: "/analytics", label: "Analytics" },
];

const ALL_MORE: (NavItem & { hidden?: boolean })[] = [
  { href: "/orders", label: "Limit orders", description: "Single-bin orders on DLMM pools" },
  { href: "/pools/create", label: "Create pool", description: "v4, DLMM or DAMM" },
  { href: "/events", label: "Event feed", description: "Live on-chain activity" },
  { href: "/buyback", label: "Buyback & burn", description: "Protocol revenue into AETH", hidden: !FEATURES.buyback },
  { href: "/contracts", label: "Contracts", description: "Every deployed address" },
  { href: "/developers", label: "Developers", description: "SDK and REST API" },
];

const visible = (items: (NavItem & { hidden?: boolean })[]): NavItem[] => items.filter((i) => !i.hidden).map(({ hidden: _hidden, ...i }) => i);

export const PRIMARY_NAV = visible(ALL_PRIMARY);
export const MORE_NAV = visible(ALL_MORE);

export const RESOURCE_NAV: NavItem[] = [
  { href: "/docs", label: "Docs", description: "How Aethra works" },
  { href: "/developers", label: "Developers", description: "SDK and REST API" },
  { href: "/contracts", label: "Contracts", description: "Every deployed address" },
];
