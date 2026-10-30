import { expect, test } from "@playwright/test";

test("hero: chain badge, ring visual, and the glyph ribbon held back until the page leaves the hero", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toContainText("Every venue.");
  await expect(page.getByText("On Robinhood Chain", { exact: true })).toBeVisible();
  await expect(page.locator(".hero-ring[data-ready]")).toBeAttached({ timeout: 10_000 });
  await expect(page.locator(".hero-ring")).not.toHaveAttribute("data-off", "");
  await page.locator("#section-router").scrollIntoViewIfNeeded();
  await expect(page.locator(".hero-ring")).toHaveAttribute("data-off", "");
});

test("section titles use the new copy and every title line fits on one line", async ({ page }) => {
  await page.goto("/");
  for (const title of ["Volatility-aware fees.", "Oracle-guarded markets.", "Precision liquidity.", "Bin by bin.", "Type-safe SDK.", "Public REST API."]) {
    await expect(page.getByRole("heading", { level: 2 }).filter({ hasText: title })).toHaveCount(1);
  }
  const wrapped = await page.$$eval("section h1 span.block, section h2 span.block", (lines) =>
    lines
      .filter((l) => l.getBoundingClientRect().height > parseFloat(getComputedStyle(l).fontSize) * 1.4)
      .map((l) => l.textContent),
  );
  expect(wrapped).toEqual([]);
});

test("cyber buttons: decode keeps the accessible name, press replays the glitch and bursts sparks", async ({ page }) => {
  await page.goto("/");
  const launch = page.getByRole("link", { name: "Launch app" });
  await launch.hover();
  await expect(page.getByRole("link", { name: "Launch app" })).toBeVisible();
  const box = (await launch.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect(launch).toHaveAttribute("data-fx-hit", "");
  await expect(page.locator(".fx-burst")).toHaveCount(1);
  // release elsewhere so the press does not navigate
  await page.mouse.move(5, 400);
  await page.mouse.up();
  await expect(page.locator(".fx-burst")).toHaveCount(0);
  await expect(launch).not.toHaveAttribute("data-fx-hit", "");
});
