# Aethra Fi: style guide

What we take from the UI reference (quantus.com plus `docs/ui-reference/website-ui-reference-1.png`) is its **style and vibe** only. Page structure, flows and features follow Aethra Fi.

**The vibe in one line:** a quiet, technical terminal, close to a lab instrument panel. It has near-black warm neutrals, hairline borders, sharp corners, small uppercase mono labels with wide tracking, large calm grotesk headlines, a single loud accent, and a subtle generative dot or character field in the background. Aethra's accent is **lime `#86F61F`**, and the brand logo's lime-to-teal gradient supplies the secondary accent.

---

## 1. Palette

### Sampled from the reference (dark)

| Sample | Hex | Use in reference |
|---|---|---|
| Page background | `#0E0E0E` | the whole canvas, about 90% of pixels |
| Hairline border | `#2D2D2C` | card outlines and table rules |
| Deep border / divider | `#1F1B18` | inner dividers |
| Muted text | `#6F6E6D` | labels and captions |
| Secondary text | `#B0B0AF` | body copy |
| Primary text | `#D6D5D5` / near white | headlines |
| Accent | `#F36633` (orange) | CTAs, numbers, section rules. **Replaced by lime.** |
| Status green | about `#3DD68C` | "SECURE" and "LIVE" chips |
| Accent tint | `#2A1812` | chip backgrounds (accent at ~12% on bg). Re-tinted to lime for Aethra. |

### Aethra tokens

The primary colour is fixed: **`#86F61F`**.

**Primary scale**

| 50 | 100 | 200 | 300 | 400 | **500** | 600 | 700 | 800 | 900 | 950 |
|---|---|---|---|---|---|---|---|---|---|---|
| `#F4FEE8` | `#E7FDCD` | `#D0FBA1` | `#B2F96A` | `#9AF73F` | **`#86F61F`** | `#68D00B` | `#3A7A0A` | `#336810` | `#2B5712` | `#163204` |

**Theme tokens.** These are CSS variables in `apps/web/src/styles/tokens.css`, defined for both themes. The Tailwind names map onto them.

| Token | Dark (default) | Light | Notes |
|---|---|---|---|
| `--bg` | `#0E0E0D` | `#F5F5F1` | warm, never pure black or white |
| `--bg-elevated` | `#121211` | `#FAFAF7` | |
| `--surface` | `#151514` | `#FFFFFF` | cards |
| `--surface-2` | `#1B1B19` | `#EFEFEA` | inputs and hover rows |
| `--border` | `#2A2A28` | `#DAD9D3` | hairline, 1px |
| `--border-strong` | `#3A3A37` | `#BFBEB7` | |
| `--text` | `#EDEDEA` | `#121211` | 16.5 / 17.2 contrast |
| `--text-2` | `#B3B2AE` | `#3B3A37` | body copy |
| `--muted` | `#8A8985` | `#5E5D59` | labels; AA on bg and surface in both themes |
| `--primary` | `#86F61F` | `#86F61F` | fills: buttons, chart lines, dots |
| `--primary-hover` | `#9AF73F` | `#68D00B` | |
| `--primary-active` | `#68D00B` | `#4F9E0C` | |
| `--primary-fg` | `#0B1004` | `#0B1004` | text on a primary fill (14:1) |
| `--primary-text` | `#86F61F` | `#3A7A0A` | primary used **as text** (14:1 / 4.8:1) |
| `--primary-soft` | `rgb(134 246 31 / 0.10)` | `rgb(58 122 10 / 0.10)` | chip and tint backgrounds |
| `--ring` | `#86F61F` | `#3A7A0A` | focus ring |
| `--accent` | `#2ED3B7` | `#0E7C6B` | secondary accent (teal, from the logo gradient) |
| `--accent-soft` | `rgb(46 211 183 / 0.10)` | `rgb(14 124 107 / 0.10)` | |
| `--success` | `#86F61F` | `#3A7A0A` | success uses the brand green |
| `--danger` | `#FF6B5E` | `#C4321F` | |
| `--warning` | `#F5B53D` | `#9A5B00` | |
| `--info` | `#2ED3B7` | `#0E7C6B` | |
| `--glow` | `0 0 0 1px rgb(134 246 31/.25), 0 0 32px -4px rgb(134 246 31/.35)` | `0 0 0 1px rgb(58 122 10/.25), 0 8px 24px -8px rgb(58 122 10/.25)` | |
| `--shadow-card` | `none` (borders only) | `0 1px 0 rgb(18 18 17/.04)` | |

Every text and background pair above was checked against WCAG AA (≥ 4.5:1). The script output is recorded in `docs/PROGRESS.md`.

**Chart series**, in both themes: primary, accent, `#F5B53D`, `#A78BFA`, `#FF6B5E`, then `--muted`. In light mode, lines use the `-text` variants so they stay visible on white.

## 2. Typography

The reference pairs a neo-grotesk display face with a monospace face for every label, number and button. Our open-source equivalents:

- **Geist** (SIL OFL), for headings and body.
- **Geist Mono** (SIL OFL), for labels, buttons, numbers, addresses, tickers and table headers.

Both come from the `geist` npm package, so they are self-hosted with no external font CDN.

| Role | Font | Size / line | Weight | Tracking | Case |
|---|---|---|---|---|---|
| Display (hero) | Geist | 56–72px / 1.02 | 500 | -0.03em | Sentence |
| H1 | Geist | 40px / 1.1 | 500 | -0.02em | Sentence |
| H2 | Geist | 28–32px / 1.15 | 500 | -0.015em | Sentence |
| H3 | Geist | 18–20px / 1.3 | 500 | -0.01em | |
| Body | Geist | 15–16px / 1.6 | 400 | 0 | |
| Small | Geist | 13px / 1.5 | 400 | 0 | |
| Eyebrow / label | Geist Mono | 11px / 1.4 | 400–500 | **0.18em** | UPPERCASE |
| Button | Geist Mono | 12px | 500 | 0.14em | UPPERCASE |
| Numbers / KPIs | Geist Mono | 24–48px | 400 | -0.02em | tabular-nums |

## 3. Spacing, radius, borders

- **Spacing scale:** 4px base (`4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 96, 128`). Sections are generous (96–128px apart on desktop, 64px on mobile). Cards are dense inside (16–24px padding).
- **Radius:** sharp. `--radius-none: 0` for cards and tables. `--radius-sm: 2px` for buttons, inputs and chips. `--radius-full` only for status dots and avatars.
- **Borders:** 1px hairline `--border` everywhere. Grids of cards **share** borders, like table cells, instead of floating apart.
- **Corner brackets:** featured panels get small L-shaped corner ticks (8px, `--border-strong`) outside the box, as on an instrument frame.
- **Section rule:** a 1px full-bleed line in `--primary` at 40% opacity separates major landing sections.

## 4. Information density

- **Marketing pages:** airy. One idea per section, a large headline, an eyebrow label (`01 / ECOSYSTEM`) and a short sub-line.
- **App pages:** dense but calm. Key–value rows use a mono muted label on the left and a mono value on the right. Tables have 44px rows and hairline separators.
- **Status dots:** a 6px dot (primary when live, warning when degraded, danger when halted) sits before mono labels such as `● INDEXER LIVE`.
- **Ticker strip:** a full-width mono row of `LABEL value` cells divided by hairlines (block height, TVL, 24h volume, gas). It scrolls slowly.

## 5. Components

- **Buttons.** All buttons are mono uppercase with 0.14em tracking and a 2px radius. Primary and secondary buttons are 40px tall; the ghost button is 32px.
  - *Primary:* `--primary` fill and `--primary-fg` text. Hover uses `--primary-hover` plus `--glow`.
  - *Secondary:* transparent with a 1px `--border-strong` border and `--text`. Hover turns the border `--primary` and the text `--primary-text`.
  - *Ghost:* text only.
  - *Target brackets* (`.fx-cyber`, landing buttons and the header only; app pages stay calm). On hover and keyboard focus, four L brackets in `--primary-text` open 4px outward around the control. On press, the control nudges down 1px and the brackets lock onto its edge, then spring back on release. CSS only, no glitch or text effects.
- **Cards.** `--surface` background, 1px `--border`, no shadow in dark mode. Header row: an eyebrow label on the left and a status chip on the right.
- **Chips / badges.** Mono 10–11px uppercase with 2px radius, a `*-soft` background and `*-text` coloured text (for example `ORACLE GUARDED`, `DYNAMIC FEE`, `LOCKED`).
- **Inputs.** `--surface-2` background with a 1px `--border` and a 2px radius. Focus shows a 1px `--ring` border plus a 3px soft ring. Numeric inputs use Geist Mono at 28px for swap amounts.
- **Tables.** Sticky mono uppercase muted headers and hairline row dividers. Hovered rows get `--surface-2`.
- **Tabs.** Underline style: a 1px bottom border, with the active tab in `--primary-text` and a 2px underline.
- **Icons.** `lucide-react` at 16px with a 1.5 stroke, inheriting `currentColor`. No filled or emoji icons.

## 6. Motion

- **Glyph ribbon.** One WebGL ribbon of ~5.3k glyphs sits behind the landing and morphs into a shape per section. The hero shape is the liquidity ring, a flattened torus of glyphs flowing around its axis. Its inner rim glows, and orbit tracks with a few bright nodes run around and inside it. The form comes from `docs/ui-reference/hero-ring-shape-reference.jpg`, which is a shape reference only. The ring sways less than the other shapes, so it stays close to level.
- **Generative background.** A slow canvas field of characters or dots (`· : + ×`) in the hero. Density follows a travelling sine wave tinted with `--primary` at 15–35% opacity, and the cursor nudges the wave frequency. It respects `prefers-reduced-motion` by rendering a static frame.
- **Micro-interactions:** 150ms `cubic-bezier(.2,.8,.2,1)` on colour and border. Number changes tick, then fade, over 300ms.
- **Section reveal:** 8px rise plus a fade over 400ms, once only, staggered by 60ms.
- **Ticker:** linear marquee at 40s per loop, paused on hover.
- **Loading:** skeleton shimmer in `--surface-2`, and a blinking mono caret `▍` for "computing route".

## 7. Brand assets

- The logo is `docs/brand/aethra-logo.svg`: a lime-to-teal swept mark owned by Aethra Fi. The web app ships optimized raster or SVG exports in `apps/web/public/brand/`.
- The wordmark is "AETHRA" set in Geist Mono at 0.2em tracking, beside the mark.
- Copy is original to Aethra Fi. Nothing is reused from the reference site.
