export interface NavItem {
  href: string;
  label: string;
  description?: string;
}

export const PRIMARY_NAV: NavItem[] = [
  { href: "/swap", label: "Swap" },
  { href: "/pools", label: "Pools" },
  { href: "/positions", label: "Positions" },
  { href: "/launch", label: "Launch" },
  { href: "/credit", label: "Credit" },
  { href: "/analytics", label: "Analytics" },
];

export const MORE_NAV: NavItem[] = [
  { href: "/orders", label: "Limit orders", description: "Single-bin orders on DLMM pools" },
  { href: "/pools/create", label: "Create pool", description: "v4, DLMM or DAMM" },
  { href: "/events", label: "Event feed", description: "Live on-chain activity" },
  { href: "/buyback", label: "Buyback & burn", description: "Protocol revenue into AETH" },
  { href: "/contracts", label: "Contracts", description: "Every deployed address" },
  { href: "/developers", label: "Developers", description: "SDK and REST API" },
];
