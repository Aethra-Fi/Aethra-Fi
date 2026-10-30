import { expect, test } from "@playwright/test";

const PAGES = ["/", "/swap", "/pools", "/positions", "/faucet"];
const OUT = "../../docs/ui-style/screens";

test("dark is the default theme for new visitors", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" }); // the OS preference must not win
  await page.goto("/");
  await expect(page.locator("html")).toHaveClass(/dark/);
});

test("theme toggle switches and persists", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: /switch to light theme/i }).click();
  await expect(page.locator("html")).not.toHaveClass(/dark/);
  await page.reload();
  await expect(page.locator("html")).not.toHaveClass(/dark/);
});

for (const theme of ["dark", "light"] as const) {
  for (const path of PAGES) {
    test(`screenshot ${theme} ${path}`, async ({ page }) => {
      await page.addInitScript((t) => {
        try {
          localStorage.setItem("aethra-theme", t);
        } catch {}
      }, theme);
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.goto(path);
      await expect(page.locator("html")).toHaveClass(theme === "dark" ? /dark/ : /^(?!.*dark)/);
      // the faucet reads its token list from the chain
      if (path === "/faucet") await expect(page.getByText("Aethra Test USD")).toBeVisible({ timeout: 20_000 });
      await page.waitForTimeout(800);
      const name = path === "/" ? "landing" : path.slice(1);
      await page.screenshot({ path: `${OUT}/${name}-${theme}.png`, fullPage: false });
    });
  }
}
