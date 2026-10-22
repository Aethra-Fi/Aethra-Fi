// Builds optimized brand rasters from docs/brand/aethra-logo.svg (1 MB, embedded rasters) with ImageMagick.
// # Jalankan di: ROOT/apps/web
//   pnpm brand
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const web = resolve(here, "..");
const src = resolve(web, "../../docs/brand/aethra-logo.svg");
const out = join(web, "public/brand");
const app = join(web, "src/app");
const mono = join(web, "node_modules/geist/dist/fonts/geist-mono/GeistMono-Medium.ttf");
const monoRegular = join(web, "node_modules/geist/dist/fonts/geist-mono/GeistMono-Regular.ttf");
const BG = "#0E0E0D";

const tmp = mkdtempSync(join(tmpdir(), "aethra-brand-"));
const m = (...args) => execFileSync("magick", args, { stdio: "inherit" });

mkdirSync(out, { recursive: true });

// 1. Rasterize once at high resolution, trim, pad to a centered square master.
const master = join(tmp, "master.png");
m("-background", "none", "-density", "192", src, "-resize", "2048x2048", "-trim", "+repage",
  "-gravity", "center", "-background", "none", "-extent", "%[fx:max(w,h)*1.08]x%[fx:max(w,h)*1.08]", master);

// 2. Square marks.
for (const s of [32, 64, 128, 256, 512]) {
  m(master, "-filter", "Lanczos", "-resize", `${s}x${s}`, "-strip", "-depth", "8", "-define", "png:compression-level=9",
    join(out, `aethra-mark-${s}.png`));
}
m(master, "-resize", "512x512", "-strip", "-quality", "88", "-define", "webp:alpha-quality=90", join(out, "aethra-mark.webp"));

// 3. App icons (Next.js file conventions).
m(master, "-resize", "256x256", "-strip", "-depth", "8", join(app, "icon.png"));
m("-size", "180x180", `xc:${BG}`, "(", master, "-resize", "136x136", ")", "-gravity", "center", "-composite", "-strip", "-depth", "8",
  join(app, "apple-icon.png"));
m(master, "-define", "icon:auto-resize=48,32,16", join(app, "favicon.ico"));

// 4. Original OG image: dark field, dot grid, mark + AETHRA wordmark in Geist Mono.
const dots = join(tmp, "dots.png");
m("-size", "24x24", "xc:none", "-fill", "rgba(134,246,31,0.18)", "-draw", "rectangle 11,11 12,12", dots);
const og = join(out, "og.png");
m(
  "-size", "1200x630", `xc:${BG}`,
  "(", "-size", "1200x630", `tile:${dots}`, ")", "-composite",
  // vignette that fades the dot field toward the left text column
  "(", "-size", "630x1200", "gradient:rgba(14,14,13,1)-rgba(14,14,13,0)", "-rotate", "90", ")", "-geometry", "+0+0", "-composite",
  "(", master, "-resize", "380x380", ")", "-gravity", "east", "-geometry", "+80+0", "-composite",
  "-gravity", "northwest",
  "-fill", "#86F61F", "-draw", "rectangle 80,80 86,86",
  "-font", monoRegular, "-pointsize", "18", "-fill", "#8A8985", "-kerning", "3", "-annotate", "+100+74", "LIQUIDITY LAYER / ROBINHOOD CHAIN",
  "-font", mono, "-pointsize", "112", "-fill", "#EDEDEA", "-kerning", "22", "-annotate", "+76+230", "AETHRA",
  "-font", monoRegular, "-pointsize", "26", "-fill", "#B3B2AE", "-kerning", "1", "-annotate", "+80+400",
  "One router across hook pools, bins\nand dynamic ranges.",
  "-fill", "#2A2A28", "-draw", "rectangle 0,548 1200,549",
  "-font", monoRegular, "-pointsize", "16", "-fill", "#8A8985", "-kerning", "3", "-annotate", "+80+572", "SWAP   POOLS   LAUNCH   CREDIT   BUYBACK",
  "-fill", "#86F61F", "-annotate", "+928+572", "AETHRA.FI",
  "-strip", "-depth", "8", "-define", "png:compression-level=9", og,
);
m(og, "-strip", "-depth", "8", join(app, "opengraph-image.png"));

rmSync(tmp, { recursive: true, force: true });
console.log("brand assets written to public/brand and src/app");
