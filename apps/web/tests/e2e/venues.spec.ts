import { expect, test } from "@playwright/test";

// Venues follow the hub's on-chain gate (hub.isRegistrar(factory)). Testnet has DLMM and DAMM open.
test("create pool offers the venues the hub has open", async ({ page }) => {
  test.skip(process.env.NEXT_PUBLIC_NETWORK !== "testnet", "testnet build only");
  await page.goto("/pools/create");
  await expect(page.getByRole("button", { name: /DLMM/ })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByRole("button", { name: /DAMM/ })).toBeVisible();
  await page.goto("/orders");
  await expect(page.getByText("Limit orders are not open on this network yet")).toHaveCount(0);
});
