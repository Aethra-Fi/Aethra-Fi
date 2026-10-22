"use client";

import { useEffect, useState } from "react";
import { useTheme } from "next-themes";

export interface ChartColors {
  series: string[];
  primary: string;
  accent: string;
  text: string;
  muted: string;
  grid: string;
  border: string;
  surface: string;
  bg: string;
  danger: string;
  warning: string;
  /** rgba() helper for a token at an alpha */
  alpha: (token: string, a: number) => string;
}

function read(): ChartColors {
  const s = getComputedStyle(document.documentElement);
  const v = (name: string) => s.getPropertyValue(`--${name}`).trim() || "0 0 0";
  const rgb = (name: string) => `rgb(${v(name).split(/\s+/).join(", ")})`;
  return {
    series: [1, 2, 3, 4, 5, 6].map((i) => rgb(`chart-${i}`)),
    primary: rgb("chart-1"),
    accent: rgb("chart-2"),
    text: rgb("text"),
    muted: rgb("muted"),
    grid: rgb("chart-grid"),
    border: rgb("border"),
    surface: rgb("surface"),
    bg: rgb("bg"),
    danger: rgb("danger"),
    warning: rgb("warning"),
    alpha: (token, a) => `rgba(${v(token).split(/\s+/).join(", ")}, ${a})`,
  };
}

const FALLBACK: ChartColors = {
  series: [],
  primary: "currentColor",
  accent: "currentColor",
  text: "currentColor",
  muted: "currentColor",
  grid: "transparent",
  border: "transparent",
  surface: "transparent",
  bg: "transparent",
  danger: "currentColor",
  warning: "currentColor",
  alpha: () => "transparent",
};

/** Theme-aware chart colours read from CSS variables at runtime; re-reads when the theme changes. */
export function useChartColors(): ChartColors & { ready: boolean; theme: string | undefined } {
  const { resolvedTheme } = useTheme();
  const [colors, setColors] = useState<ChartColors | null>(null);
  useEffect(() => {
    // wait a frame so next-themes has applied the class before reading variables
    const id = requestAnimationFrame(() => setColors(read()));
    return () => cancelAnimationFrame(id);
  }, [resolvedTheme]);
  return { ...(colors ?? FALLBACK), ready: colors !== null, theme: resolvedTheme };
}
