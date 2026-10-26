/**
 * Feature flags for modules that are built but not shown yet. Set NEXT_PUBLIC_FEATURES to a comma list
 * (launchpad,credit,buyback) to switch them back on; the contracts for them are not deployed while hidden.
 */
const enabled = new Set((process.env.NEXT_PUBLIC_FEATURES ?? "").split(",").map((s) => s.trim()).filter(Boolean));

export const FEATURES = {
  launchpad: enabled.has("launchpad"),
  credit: enabled.has("credit"),
  buyback: enabled.has("buyback"),
} as const;
