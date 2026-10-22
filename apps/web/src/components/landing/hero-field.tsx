"use client";

import * as React from "react";
import { useTheme } from "next-themes";

const GLYPHS = [" ", "·", ":", "+", "×"];
const CELL = 18;

/**
 * Slow generative field of glyphs whose density follows a travelling sine wave, tinted with --primary.
 * The cursor nudges the wave frequency. Renders one static frame under prefers-reduced-motion.
 */
export function HeroField({ className }: { className?: string }) {
  const ref = React.useRef<HTMLCanvasElement>(null);
  const { resolvedTheme } = useTheme();

  React.useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const styles = getComputedStyle(document.documentElement);
    const rgb = styles.getPropertyValue("--primary").trim().split(/\s+/).join(",");
    const min = Number(styles.getPropertyValue("--field-opacity-min")) || 0.15;
    const max = Number(styles.getPropertyValue("--field-opacity-max")) || 0.35;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    let w = 0;
    let h = 0;
    let raf = 0;
    let freq = 1;
    let targetFreq = 1;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);

    const resize = () => {
      const r = canvas.getBoundingClientRect();
      w = r.width;
      h = r.height;
      canvas.width = w * dpr;
      canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.font = `12px var(--font-geist-mono), ui-monospace, monospace`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
    };

    const draw = (t: number) => {
      freq += (targetFreq - freq) * 0.02;
      ctx.clearRect(0, 0, w, h);
      const cols = Math.ceil(w / CELL);
      const rows = Math.ceil(h / CELL);
      for (let y = 0; y < rows; y++) {
        for (let x = 0; x < cols; x++) {
          const nx = x / cols;
          const ny = y / rows;
          const v =
            Math.sin(nx * 6 * freq + t * 0.00035) * 0.5 +
            Math.sin((nx + ny) * 4 - t * 0.00022) * 0.35 +
            Math.sin(ny * 9 * freq + t * 0.0003) * 0.15;
          const n = (v + 1) / 2; // 0..1
          const g = GLYPHS[Math.min(GLYPHS.length - 1, Math.floor(n * GLYPHS.length))]!;
          if (g === " ") continue;
          // fade toward the left so the headline stays readable
          const fade = Math.min(1, 0.25 + nx * 1.1);
          ctx.fillStyle = `rgba(${rgb},${(min + (max - min) * n) * fade})`;
          ctx.fillText(g, x * CELL + CELL / 2, y * CELL + CELL / 2);
        }
      }
    };

    const loop = (t: number) => {
      draw(t);
      raf = requestAnimationFrame(loop);
    };

    const onMove = (e: PointerEvent) => {
      targetFreq = 0.8 + (e.clientX / window.innerWidth) * 0.6;
    };

    resize();
    window.addEventListener("resize", resize);
    if (reduce) draw(0);
    else {
      window.addEventListener("pointermove", onMove);
      raf = requestAnimationFrame(loop);
    }
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
      window.removeEventListener("pointermove", onMove);
    };
  }, [resolvedTheme]);

  return <canvas ref={ref} className={className} aria-hidden />;
}
