"use client";

import { Bar, BarChart, CartesianGrid, Cell, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { useChartColors } from "@/hooks/use-chart-colors";
import type { Point } from "./area-chart";

/** Single-series bar chart over time (volume, fees, trades) that follows the active theme's chart tokens. */
export function ThemedBarChart({
  data,
  height = 260,
  format = (v) => v.toLocaleString(),
  color = "accent",
  hourly = false,
  xFormat,
  highlight,
}: {
  data: Point[];
  height?: number;
  format?: (v: number) => string;
  color?: "primary" | "accent";
  /** label ticks with the hour instead of the day */
  hourly?: boolean;
  /** categorical x axis: formats `t` for ticks and the tooltip instead of reading it as a date */
  xFormat?: (t: string) => string;
  /** `t` of the bar drawn in the other series color (e.g. the active bin) */
  highlight?: string;
}) {
  const c = useChartColors();
  if (!c.ready) return <div className="skeleton w-full" style={{ height }} />;
  const fill = color === "primary" ? c.primary : c.accent;
  const tick = (t: string) =>
    xFormat ? xFormat(t) : hourly ? new Date(t).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }) : new Date(t).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart data={data} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
        <CartesianGrid stroke={c.grid} vertical={false} />
        <XAxis dataKey="t" tick={{ fill: c.muted, fontSize: 11, fontFamily: "var(--font-geist-mono)" }} tickFormatter={tick} stroke={c.border} minTickGap={32} />
        <YAxis
          tick={{ fill: c.muted, fontSize: 11, fontFamily: "var(--font-geist-mono)" }}
          tickFormatter={format}
          stroke={c.border}
          width={72}
          orientation="right"
        />
        <Tooltip
          cursor={{ fill: c.alpha("chart-grid", 0.4) }}
          contentStyle={{ background: c.surface, border: `1px solid ${c.border}`, borderRadius: 2, fontFamily: "var(--font-geist-mono)", fontSize: 12 }}
          labelStyle={{ color: c.muted }}
          itemStyle={{ color: c.text }}
          labelFormatter={(t: string) => (xFormat ? xFormat(t) : new Date(t).toLocaleString())}
          formatter={(v: number) => [format(v), ""]}
        />
        <Bar dataKey="v" fill={fill} radius={[1, 1, 0, 0]} isAnimationActive={false} maxBarSize={28}>
          {highlight !== undefined && data.map((d) => <Cell key={d.t} fill={d.t === highlight ? (color === "primary" ? c.accent : c.primary) : fill} />)}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}
