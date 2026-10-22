// Small technical schematics, one per landing section. Pure SVG drawn with currentColor and design tokens,
// animated with CSS only (paused under prefers-reduced-motion by the global rule in globals.css).

const stroke = "stroke-[1.25] [vector-effect:non-scaling-stroke]";

function Frame({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <figure className="relative w-full max-w-[320px] border bg-bg/70 p-3 backdrop-blur-sm">
      <span className="absolute -left-px -top-px size-2 border-l border-t border-primary" />
      <span className="absolute -right-px -top-px size-2 border-r border-t border-primary" />
      <span className="absolute -bottom-px -left-px size-2 border-b border-l border-primary" />
      <span className="absolute -bottom-px -right-px size-2 border-b border-r border-primary" />
      <figcaption className="mb-2 flex justify-between font-mono text-[10px] uppercase tracking-eyebrow text-muted">
        <span>{label}</span>
        <span className="text-primary-text">● live</span>
      </figcaption>
      <svg viewBox="0 0 280 120" className="h-auto w-full text-fg-2" aria-hidden>
        {children}
      </svg>
    </figure>
  );
}

function Grid() {
  return (
    <g className="stroke-border" strokeWidth="1">
      {Array.from({ length: 8 }, (_, i) => (
        <line key={`v${i}`} x1={i * 40} y1="0" x2={i * 40} y2="120" />
      ))}
      {Array.from({ length: 4 }, (_, i) => (
        <line key={`h${i}`} x1="0" y1={i * 40} x2="280" y2={i * 40} />
      ))}
    </g>
  );
}

export function RouterSchematic() {
  const nodes: [number, number, string][] = [
    [20, 60, "IN"],
    [140, 20, "V4"],
    [140, 60, "DLMM"],
    [140, 100, "DAMM"],
    [260, 60, "OUT"],
  ];
  return (
    <Frame label="route.quote · 3 paths">
      <Grid />
      {[1, 2, 3].map((i) => (
        <g key={i} className="fill-none">
          <path d={`M20 60 C80 60 80 ${nodes[i]![1]} 140 ${nodes[i]![1]}`} className={`stroke-border-strong ${stroke}`} />
          <path d={`M140 ${nodes[i]![1]} C200 ${nodes[i]![1]} 200 60 260 60`} className={`stroke-border-strong ${stroke}`} />
        </g>
      ))}
      <path d="M20 60 C80 60 80 60 140 60 C200 60 200 60 260 60" className={`fill-none stroke-primary ${stroke} [stroke-dasharray:6_6] animate-[dash_1.2s_linear_infinite]`} />
      {nodes.map(([x, y, l]) => (
        <g key={l}>
          <rect x={x - 16} y={y - 8} width="32" height="16" className="fill-surface stroke-border-strong" />
          <text x={x} y={y + 3} textAnchor="middle" className="fill-current font-mono text-[8px]">
            {l}
          </text>
        </g>
      ))}
    </Frame>
  );
}

export function FeeSchematic() {
  const pts = Array.from({ length: 57 }, (_, i) => {
    const x = i * 5;
    const vol = Math.exp(-(((i - 34) / 8) ** 2));
    return `${x},${100 - 18 - vol * 64 - Math.sin(i * 0.9) * 3}`;
  }).join(" ");
  return (
    <Frame label="fee(σ) · base → max">
      <Grid />
      <line x1="0" y1="82" x2="280" y2="82" className="stroke-accent [stroke-dasharray:3_4]" />
      <text x="4" y="78" className="fill-accent font-mono text-[8px]">
        BASE 0.30%
      </text>
      <polyline points={pts} className={`fill-none stroke-primary ${stroke}`} />
      <line x1="170" y1="0" x2="170" y2="120" className="stroke-primary/60 animate-[scan_4s_ease-in-out_infinite_alternate]" />
      <text x="232" y="14" className="fill-current font-mono text-[8px]">
        σ ↑ fee ↑
      </text>
    </Frame>
  );
}

export function BinsSchematic() {
  return (
    <Frame label="bins · step 25 bps">
      <Grid />
      {Array.from({ length: 21 }, (_, i) => {
        const d = (i - 10) / 4.5;
        const h = Math.exp(-d * d) * 84 + 6;
        return (
          <rect
            key={i}
            x={8 + i * 12.8}
            y={110 - h}
            width="9"
            height={h}
            className={i < 10 ? "fill-accent/70" : i === 10 ? "fill-fg" : "fill-primary/70"}
          />
        );
      })}
      <line x1="140" y1="0" x2="140" y2="120" className="stroke-fg [stroke-dasharray:2_3]" />
      <text x="146" y="12" className="fill-current font-mono text-[8px]">
        ACTIVE
      </text>
      <rect x="203" y="20" width="9" height="90" className="fill-none stroke-warning [stroke-dasharray:3_2]" />
      <text x="216" y="28" className="fill-warning font-mono text-[8px]">
        LIMIT
      </text>
    </Frame>
  );
}

export function CurveSchematic() {
  const pts = Array.from({ length: 50 }, (_, i) => {
    const x = 10 + i * 5.3;
    const y = 110 - (Math.pow(i / 49, 2.2) * 96 + 2);
    return `${x},${y}`;
  }).join(" ");
  return (
    <Frame label="x·y = k · graduation">
      <Grid />
      <polyline points={pts} className={`fill-none stroke-primary ${stroke}`} />
      <line x1="270" y1="0" x2="270" y2="120" className="stroke-warning [stroke-dasharray:4_3]" />
      <text x="226" y="118" className="fill-warning font-mono text-[8px]">
        GRAD
      </text>
      <circle r="3.5" className="fill-primary">
        <animateMotion dur="6s" repeatCount="indefinite" path={`M${pts.split(" ").join(" L")}`} />
      </circle>
    </Frame>
  );
}

export function HealthSchematic() {
  return (
    <Frame label="health factor · ltv 50%">
      <Grid />
      <path d="M40 104 A100 100 0 0 1 240 104" className="fill-none stroke-border-strong [stroke-width:10]" />
      <path d="M40 104 A100 100 0 0 1 113 9" className="fill-none stroke-danger/70 [stroke-width:10]" />
      <path d="M113 9 A100 100 0 0 1 180 14" className="fill-none stroke-warning/70 [stroke-width:10]" />
      <path d="M180 14 A100 100 0 0 1 240 104" className="fill-none stroke-primary/80 [stroke-width:10]" />
      <g className="origin-[140px_104px] animate-[needle_5s_ease-in-out_infinite_alternate]">
        <line x1="140" y1="104" x2="205" y2="40" className="stroke-fg [stroke-width:2]" />
      </g>
      <circle cx="140" cy="104" r="4" className="fill-fg" />
      <text x="140" y="92" textAnchor="middle" className="fill-current font-mono text-[9px]">
        HF 1.84
      </text>
    </Frame>
  );
}

export function BurnSchematic() {
  return (
    <Frame label="fees → buyback → burn">
      <Grid />
      {[
        [30, "FEES"],
        [140, "SWAP"],
        [250, "BURN"],
      ].map(([x, l]) => (
        <g key={l as string}>
          <circle cx={x as number} cy="60" r="20" className={l === "BURN" ? "fill-warning/15 stroke-warning" : "fill-surface stroke-border-strong"} />
          <text x={x as number} y="63" textAnchor="middle" className="fill-current font-mono text-[8px]">
            {l}
          </text>
        </g>
      ))}
      <path d="M52 60 H118 M162 60 H228" className={`stroke-primary ${stroke} [stroke-dasharray:5_5] animate-[dash_0.9s_linear_infinite]`} />
      <text x="85" y="52" textAnchor="middle" className="fill-muted font-mono text-[8px]">
        80%
      </text>
      <text x="85" y="80" textAnchor="middle" className="fill-muted font-mono text-[8px]">
        20% → treasury
      </text>
      <text x="195" y="52" textAnchor="middle" className="fill-muted font-mono text-[8px]">
        → AETH
      </text>
    </Frame>
  );
}

export function CodeSchematic() {
  const lines = [
    ["const", " d = getDeployment(", '"testnet"', ")"],
    ["await", " client.simulateContract({", "", ""],
    ["", "  address: d.router, functionName: ", '"quote"', ","],
    ["", "  args: [hops, 10n ** 18n] })", "", ""],
  ];
  return (
    <Frame label="@aethra/sdk · typed">
      {lines.map((l, i) => (
        <text key={i} x="6" y={22 + i * 22} className="font-mono text-[8.5px]">
          <tspan className="fill-accent">{l[0]}</tspan>
          <tspan className="fill-current">{l[1]}</tspan>
          <tspan className="fill-primary">{l[2]}</tspan>
          <tspan className="fill-current">{l[3]}</tspan>
        </text>
      ))}
      <rect x="6" y="100" width="6" height="11" className="fill-primary animate-caret" />
    </Frame>
  );
}
