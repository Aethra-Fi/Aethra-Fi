// Builds the landing hero ring layers from docs/brand/hero-ring-source.jpg (a render on black) with ImageMagick.
// # Jalankan di: ROOT/apps/web
//   pnpm brand:hero
//
// The render has the old headline baked in and a black background, so:
//   1. the headline is painted out (grey pixels inside its box; the green particles there survive),
//   2. the ring and its orbits are cropped,
//   3. black becomes transparency ("unscreen": alpha = brightest channel, colour = rgb / alpha), so the layer sits
//      on any dark page exactly like the original, and the crop edges are feathered,
//   4. a light-theme variant redraws the same shapes as deep green ink with the faint haze thinned out.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const web = resolve(here, "..");
const src = resolve(web, "../../docs/brand/hero-ring-source.jpg");
const out = join(web, "public/brand");

const tmp = mkdtempSync(join(tmpdir(), "aethra-hero-"));
const m = (...args) => execFileSync("magick", args, { stdio: "inherit" });

mkdirSync(out, { recursive: true });

// 1–3: dark layer (premultiplied by black in the source, un-premultiplied here)
const dark = join(tmp, "dark.png");
m(
  src,
  "-region", "434x156+528+236", "-fx", "(max(r,max(g,b)) - min(r,min(g,b))) < 36/255 ? 0 : u", "+region",
  "-crop", "1572x694+600+30", "+repage",
  // background haze (<= ~11/255) becomes fully transparent
  "-level", "4.3%,100%",
  "(", "+clone", "-separate", "-evaluate-sequence", "max", ")",
  "-alpha", "off", "-compose", "CopyOpacity", "-composite",
  "-channel", "RGB", "-fx", "a > 0.000001 ? min(1, u / a) : 0",
  // feathered crop: 60 px left, 40 px right, 30 px top, 70 px bottom (smoothstep)
  "-channel", "A",
  "-fx", "edge = min(1, i/60) * min(1, (w-1-i)/40) * min(1, j/30) * min(1, (h-1-j)/70); u * edge * edge * (3 - 2*edge)",
  "+channel",
  dark,
);

// 4: light layer: same shapes as deep green ink, faint haze thinned
const light = join(tmp, "light.png");
m(
  dark,
  "-channel", "R", "-evaluate", "multiply", "0.252",
  "-channel", "G", "-evaluate", "multiply", "0.42",
  "-channel", "B", "-evaluate", "multiply", "0.357",
  "-channel", "A", "-fx", "pow(max(0, (u - 0.06) / 0.94), 0.85)",
  "+channel",
  light,
);

for (const [name, file] of [["dark", dark], ["light", light]]) {
  m(file, "-strip", "-quality", "72", "-define", "webp:alpha-quality=70", "-define", "webp:method=6", join(out, `hero-ring-${name}.webp`));
  m(file, "-resize", "860x", "-strip", "-quality", "72", "-define", "webp:alpha-quality=70", "-define", "webp:method=6",
    join(out, `hero-ring-${name}-860.webp`));
}

rmSync(tmp, { recursive: true, force: true });
console.log("hero ring layers written to public/brand/hero-ring-{dark,light}{,-860}.webp");
