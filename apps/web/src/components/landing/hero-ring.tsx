"use client";

import * as React from "react";
import { cn } from "@/lib/utils";

/** White orbit nodes in the ring render, as % of the layer (x, y), with a staggered ping. */
const NODES: [number, number, number][] = [
  [43.2, 20.4, 0],
  [89.1, 13.4, 1.4],
  [83.6, 51.5, 0.6],
  [83.2, 72.6, 2.2],
  [9.7, 65, 1],
];

/**
 * Hero visual: the Aethra ring render (public/brand/hero-ring-*.webp, built by `pnpm brand:hero`) with a light band
 * sweeping across its glyphs, pinging orbit nodes and a slight tilt toward the pointer. Styles in globals.css
 * (`.hero-ring`). The landing drives `--leave` (0..1) on the forwarded ref as the page scrolls out of the hero.
 */
export const HeroRing = React.forwardRef<HTMLDivElement, { className?: string }>(function HeroRing({ className }, ref) {
  const rootRef = React.useRef<HTMLDivElement>(null);
  const tiltRef = React.useRef<HTMLDivElement>(null);
  const artRef = React.useRef<HTMLDivElement>(null);
  React.useImperativeHandle(ref, () => rootRef.current!);

  // play the entrance once the theme's layer has decoded, so it never fades in as an empty box
  React.useEffect(() => {
    const root = rootRef.current;
    const art = artRef.current;
    if (!root || !art) return;
    const ready = () => root.setAttribute("data-ready", "");
    const url = /url\(["']?([^"')]+)["']?\)/.exec(getComputedStyle(art).backgroundImage)?.[1];
    if (!url) return ready();
    const img = new Image();
    img.src = url;
    const fallback = window.setTimeout(ready, 2500);
    img.decode().then(ready, ready).finally(() => window.clearTimeout(fallback));
    return () => window.clearTimeout(fallback);
  }, []);

  // tilt toward the pointer, eased; idle when the pointer rests
  React.useEffect(() => {
    const el = tiltRef.current;
    if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let raf = 0;
    let tx = 0;
    let ty = 0;
    let x = 0;
    let y = 0;
    const tick = () => {
      x += (tx - x) * 0.08;
      y += (ty - y) * 0.08;
      el.style.setProperty("--rx", `${(-y * 4).toFixed(2)}deg`);
      el.style.setProperty("--ry", `${(x * 6).toFixed(2)}deg`);
      raf = Math.abs(tx - x) + Math.abs(ty - y) > 0.002 ? requestAnimationFrame(tick) : 0;
    };
    const onMove = (e: PointerEvent) => {
      if (e.pointerType !== "mouse") return;
      tx = (e.clientX / window.innerWidth) * 2 - 1;
      ty = (e.clientY / window.innerHeight) * 2 - 1;
      if (!raf) raf = requestAnimationFrame(tick);
    };
    window.addEventListener("pointermove", onMove, { passive: true });
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("pointermove", onMove);
    };
  }, []);

  return (
    <div ref={rootRef} className={cn("hero-ring", className)} aria-hidden>
      <div ref={tiltRef} className="hero-ring-tilt">
        <div className="hero-ring-float">
          <div ref={artRef} className="hero-ring-art" />
          <div className="hero-ring-sweep" />
          {NODES.map(([x, y, delay]) => (
            <span key={`${x},${y}`} className="hero-ring-node" style={{ left: `${x}%`, top: `${y}%`, animationDelay: `${delay}s` }} />
          ))}
        </div>
      </div>
    </div>
  );
});
