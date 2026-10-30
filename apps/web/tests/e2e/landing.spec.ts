import { expect, test } from "@playwright/test";

test("hero: chain badge and the glyph ribbon (liquidity ring) behind it", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toContainText("Every venue.");
  await expect(page.getByText("On Robinhood Chain", { exact: true })).toBeVisible();
  await expect(page.getByText("FORM 00 · Liquidity ring")).toBeAttached();
  // the hero uses the same WebGL ribbon as every other section, no image layer
  await expect(page.locator("div[aria-hidden] > canvas")).toHaveCount(1, { timeout: 10_000 });
  await expect(page.locator("main img")).toHaveCount(0);
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

test("buttons: brackets open on hover and lock on press, the label never changes", async ({ page }) => {
  await page.goto("/");
  const launch = page.getByRole("link", { name: "Launch app" });
  const brackets = () => launch.evaluate((el) => {
    const s = getComputedStyle(el, "::after");
    return { opacity: s.opacity, inset: s.top };
  });
  await expect.poll(brackets).toEqual({ opacity: "0", inset: "-1px" });
  await launch.hover();
  await expect.poll(brackets).toEqual({ opacity: "1", inset: "-5px" });
  await expect(launch).toHaveText("Launch app");
  const box = (await launch.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect.poll(brackets).toEqual({ opacity: "1", inset: "-2px" });
  // release elsewhere so the press does not navigate
  await page.mouse.move(5, 400);
  await page.mouse.up();
  await expect.poll(brackets).toEqual({ opacity: "0", inset: "-1px" });
});
