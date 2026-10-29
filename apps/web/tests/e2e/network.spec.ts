import { expect, test } from "@playwright/test";

// Needs a build with NEXT_PUBLIC_NETWORK=testnet (or mainnet): pnpm build && pnpm test:e2e

test("header offers a testnet / mainnet toggle", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  await page.goto("/");
  const group = page.getByRole("group", { name: "Network" });
  test.skip(!(await group.isVisible()), "local build: single network, no toggle");
  await expect(group.getByRole("button", { name: /testnet/i })).toHaveAttribute("aria-pressed", "true");
  const mainnet = group.getByRole("button", { name: /mainnet/i });
  await expect(mainnet).toBeVisible();
  expect(errors.filter((e) => /hydrat/i.test(e))).toEqual([]);
});

test("a saved network that is not available is ignored", async ({ page }) => {
  await page.addInitScript(() => {
    try {
      localStorage.setItem("aethra-network", "mainnet");
    } catch {}
  });
  await page.goto("/");
  const group = page.getByRole("group", { name: "Network" });
  test.skip(!(await group.isVisible()), "local build: single network, no toggle");
  const mainnet = group.getByRole("button", { name: /mainnet/i });
  test.skip(await mainnet.isEnabled(), "mainnet is live: the saved choice is honoured");
  await expect(group.getByRole("button", { name: /testnet/i })).toHaveAttribute("aria-pressed", "true");
});
