"use client";

import { Area, AreaChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { useChartColors } from "@/hooks/use-chart-colors";

export interface Point {
  t: string;
  v: number;
}

/** Single-series area chart that follows the active theme's chart tokens. */
export function ThemedAreaChart({
  data,
  height = 260,
  format = (v) => v.toLocaleString(),
  color = "primary",
}: {
  data: Point[];
  height?: number;
  format?: (v: number) => string;
  color?: "primary" | "accent";
}) {
  const c = useChartColors();
  if (!c.ready) return <div className="skeleton w-full" style={{ height }} />;
  const stroke = color === "primary" ? c.primary : c.accent;
  const id = `fill-${color}`;
  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
        <defs>
          <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={stroke} stopOpacity={0.28} />
            <stop offset="100%" stopColor={stroke} stopOpacity={0} />
          </linearGradient>
        </defs>
        <CartesianGrid stroke={c.grid} vertical={false} />
        <XAxis
          dataKey="t"
          tick={{ fill: c.muted, fontSize: 11, fontFamily: "var(--font-geist-mono)" }}
          tickFormatter={(t: string) => new Date(t).toLocaleDateString(undefined, { month: "short", day: "numeric" })}
          stroke={c.border}
          minTickGap={32}
        />
        <YAxis
          tick={{ fill: c.muted, fontSize: 11, fontFamily: "var(--font-geist-mono)" }}
          tickFormatter={format}
          stroke={c.border}
          width={72}
          orientation="right"
        />
        <Tooltip
          contentStyle={{ background: c.surface, border: `1px solid ${c.border}`, borderRadius: 2, fontFamily: "var(--font-geist-mono)", fontSize: 12 }}
          labelStyle={{ color: c.muted }}
          itemStyle={{ color: c.text }}
          labelFormatter={(t: string) => new Date(t).toLocaleString()}
          formatter={(v: number) => [format(v), ""]}
        />
        <Area type="monotone" dataKey="v" stroke={stroke} strokeWidth={1.5} fill={`url(#${id})`} isAnimationActive={false} />
      </AreaChart>
    </ResponsiveContainer>
  );
}
