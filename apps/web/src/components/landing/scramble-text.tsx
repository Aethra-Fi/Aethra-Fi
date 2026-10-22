"use client";

import * as React from "react";

const NOISE = "·:+×◇01ΛΞΣ#/<>∿▓▒░";

/**
 * Decodes `text` from glyph noise, left to right, each time `active` turns on. Static under
 * prefers-reduced-motion. The real text is always in the accessible name.
 */
export function ScrambleText({ text, active, className }: { text: string; active: boolean; className?: string }) {
  const [shown, setShown] = React.useState(text);

  React.useEffect(() => {
    if (!active || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const chars = Array.from(text);
    const start = performance.now();
    const duration = 650 + chars.length * 12;
    let raf = 0;
    const step = (now: number) => {
      const p = Math.min(1, (now - start) / duration);
      const settled = Math.floor(p * chars.length);
      setShown(
        chars
          .map((c, i) => (i < settled || c === " " || c === "\n" ? c : NOISE[Math.floor(Math.random() * NOISE.length)]))
          .join(""),
      );
      if (p < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [active, text]);

  return (
    <span className={className} aria-label={text}>
      <span aria-hidden>{shown}</span>
    </span>
  );
}
