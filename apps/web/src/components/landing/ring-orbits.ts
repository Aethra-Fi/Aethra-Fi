import * as THREE from "three";
import { RING, ribbonTransform, ringContour } from "./ribbon-shaders";

// The liquidity ring's orbit layer: thin orbit lines, bead trails, lit nodes and a dust of specks around the glyph
// torus, plus the glow along the band's outer and inner edges. Drawn in the same frame as the torus (shared transform
// uniforms) and only while the hero shows the ring (uHero).

/** weights of uColorA (lime), uColorB (teal), uColorC (amber), uColorHot (near white) */
type Tint = [number, number, number, number];
/** [from, to, alpha] in turns around the ring: 0 right, .25 front, .5 left, .75 back; `to` may pass 1 */
type Span = [number, number, number];

interface Orbit {
  /** centre offset */
  c: [number, number, number];
  /** radii along x and z */
  a: number;
  b: number;
  /** own tilt about x and z, on top of the ring's */
  rx: number;
  rz: number;
  /** solid line: core half-width in px */
  line?: { spans: Span[]; width: number; tint: Tint };
  /** bead trail: spacing in ribbon units, size in px */
  beads?: { spans: Span[]; gap: number; size: number; tint: Tint };
  /** node positions, turns */
  nodes?: number[];
}

const ORBITS: Orbit[] = [
  // inner track, seen through the hole: brighter on the near left
  {
    c: [0.08, -0.04, -0.05],
    a: 0.86,
    b: 0.8,
    rx: -0.05,
    rz: 0.02,
    line: { spans: [[0.2, 0.75, 0.26], [0.75, 1.2, 0.08]], width: 0.45, tint: [0.4, 0, 0.6, 0] },
  },
  // close track: a bright arc on each flank, faint in front and behind
  {
    c: [-0.2, 0, 0.06],
    a: 2.3,
    b: 2.1,
    rx: -0.03,
    rz: -0.04,
    line: { spans: [[0.3, 0.68, 0.9], [0.68, 0.84, 0.3], [0.84, 1.1, 0.85], [0.1, 0.3, 0.18]], width: 0.65, tint: [0.15, 0, 0.55, 0.3] },
  },
  // outer track: beads on the near left and along the back, a solid stretch on the right, four nodes
  {
    c: [-0.3, 0, 0.04],
    a: 2.5,
    b: 2.45,
    rx: -0.02,
    rz: -0.09,
    line: { spans: [[0.86, 1.1, 0.9], [0.5, 0.6, 0.45]], width: 0.65, tint: [0, 0.8, 0, 0.2] },
    beads: { spans: [[0.3, 0.5, 1], [0.6, 0.86, 0.6], [0.1, 0.3, 0.55]], gap: 0.05, size: 3.2, tint: [0.1, 0.2, 0, 0.7] },
    nodes: [0.5, 0.7, 0.86, 1.06],
  },
  // low track on the near right, one node
  {
    c: [0.1, -0.12, 0.25],
    a: 2.3,
    b: 2.1,
    rx: -0.04,
    rz: -0.12,
    beads: { spans: [[0.95, 1.35, 0.65]], gap: 0.05, size: 2.6, tint: [0.3, 0.7, 0, 0] },
    nodes: [1.1],
  },
  // faint, steep track
  { c: [0.35, -0.1, 0.15], a: 2.3, b: 2.3, rx: 0.4, rz: -0.3, beads: { spans: [[0, 1, 0.25]], gap: 0.06, size: 2, tint: [0.6, 0.2, 0.2, 0] } },
];

const DUST = 3000;
const SAMPLES = 360;
const TAU = Math.PI * 2;
const X = new THREE.Vector3(1, 0, 0);
const Z = new THREE.Vector3(0, 0, 1);

const orbitLineVertex = /* glsl */ `
${ribbonTransform}
attribute vec3 aNext;
attribute vec3 aRadial;
attribute float aSide;
attribute float aCore;
attribute float aGlow;
attribute float aAlpha;
attribute float aT;
attribute float aGlint;
attribute vec4 aTint;

uniform float uTime;
uniform float uIntro;
uniform float uHero;
uniform float uGlobalAlpha;
uniform vec2 uHalfRes;
uniform float uPx;
uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;
uniform vec3 uColorHot;

varying vec3 vColor;
varying float vAlpha;
varying float vDist;
varying float vCore;
varying float vGlow;

float hash1(float n) { return fract(sin(n) * 43758.5453123); }
float noise1(float x) {
  float i = floor(x);
  float f = fract(x);
  return mix(hash1(i), hash1(i + 1.), f * f * (3. - 2. * f));
}

void main() {
  // a screen-space strip: each sample is pushed sideways by the line's half-width in pixels
  vec4 c0 = projectionMatrix * modelViewMatrix * vec4(toFrame(position), 1.);
  vec4 c1 = projectionMatrix * modelViewMatrix * vec4(toFrame(aNext), 1.);
  vec2 d = normalize((c1.xy / c1.w - c0.xy / c0.w) * uHalfRes + vec2(1e-6, 0.));
  float hw = (aCore + aGlow) * uPx;
  c0.xy += vec2(-d.y, d.x) * aSide * hw / uHalfRes * c0.w;
  gl_Position = c0;
  vDist = aSide * hw;
  vCore = aCore * uPx;
  vGlow = aGlow * uPx;

  // the band's outer (1) and inner (2) contours follow the ring's light; a slow highlight runs around them
  float g = 1.;
  if (aGlint > .5) {
    vec2 dir = normalize((frameRot() * aRadial).xy + 1e-5);
    g = ringContourGain(dir, 2. - aGlint) * (1. + .7 * pow(.5 + .5 * cos((aT - uTime * .035) * TAU), 24.));
    // uneven, slowly shifting brightness, so the edge reads as charged glyphs rather than a neon tube
    g *= .55 + .7 * noise1(aT * 70. + aGlint * 13. + uTime * .4);
  }
  // lines draw themselves in from the left when the page loads
  float reveal = smoothstep(0., .05, uIntro * 1.3 - .2 - fract(aT - .5));
  vColor = (aTint.x * uColorA + aTint.y * uColorB + aTint.z * uColorC + aTint.w * uColorHot) / max(1e-3, dot(aTint, vec4(1.)));
  vAlpha = aAlpha * g * reveal * uHero * uGlobalAlpha;
}
`;

const orbitLineFragment = /* glsl */ `
uniform float uAlphaGain;
uniform float uDark;
varying vec3 vColor;
varying float vAlpha;
varying float vDist;
varying float vCore;
varying float vGlow;

void main() {
  float x = abs(vDist);
  float core = 1. - smoothstep(vCore - .6, vCore + .6, x);
  float glow = vGlow > 0. ? exp(-pow(max(0., x - vCore) / (vGlow * .42), 2.)) * (.2 + .35 * uDark) : 0.;
  float a = min(1., (core + glow) * vAlpha * uAlphaGain);
  if (a < .004) discard;
  gl_FragColor = vec4(mix(vColor, vec3(1.), core * .3 * uDark), a);
}
`;

const orbitPointVertex = /* glsl */ `
${ribbonTransform}
attribute vec3 aC;
attribute vec2 aAB;
attribute vec2 aTilt;
attribute vec2 aSpan;
attribute float aX;
attribute float aSpeed;
attribute float aSize;
attribute float aAlpha;
attribute float aKind;
attribute vec4 aTint;

uniform float uTime;
uniform float uIntro;
uniform float uHero;
uniform float uGlobalAlpha;
uniform float uPx;
uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;
uniform vec3 uColorHot;

varying vec3 vColor;
varying float vAlpha;
varying float vKind;

void main() {
  // travel along the orbit, wrapping inside the span (beads) or around the whole orbit (nodes, dust)
  float x = fract(aX + uTime * aSpeed / aSpan.y);
  float a = (aSpan.x + x * aSpan.y) * TAU;
  vec3 p = rotZ(aTilt.y) * rotX(aTilt.x) * vec3(cos(a) * aAB.x, 0., sin(a) * aAB.y) + aC;
  vec4 mv = modelViewMatrix * vec4(toFrame(p), 1.);
  gl_Position = projectionMatrix * mv;
  gl_PointSize = aSize * uPx * 6.4 / -mv.z; // 6.4: camera distance, so sizes hold at the ring's centre

  float ends = aKind == 0. ? smoothstep(0., .08, x) * smoothstep(1., .92, x) : 1.;
  float twinkle = aKind == 2. ? max(0., .45 + .55 * sin(uTime * (.8 + fract(aX * 7.3) * 2.5) + aX * 60.)) : 1.;
  vColor = (aTint.x * uColorA + aTint.y * uColorB + aTint.z * uColorC + aTint.w * uColorHot) / max(1e-3, dot(aTint, vec4(1.)));
  vAlpha = aAlpha * ends * twinkle * smoothstep(.25, .9, uIntro) * uHero * uGlobalAlpha;
  vKind = aKind;
}
`;

const orbitPointFragment = /* glsl */ `
uniform float uAlphaGain;
uniform float uDark;
varying vec3 vColor;
varying float vAlpha;
varying float vKind;

void main() {
  vec2 q = gl_PointCoord * 2. - 1.;
  float d = length(q);
  vec3 col = vColor;
  float a;
  if (vKind == 1.) {
    // node: a small lit sphere in a soft halo
    float core = smoothstep(.36, .3, d);
    vec2 sq = q / .34;
    vec3 n = vec3(sq, sqrt(max(0., 1. - dot(sq, sq))));
    float lit = clamp(dot(n, normalize(vec3(-.45, -.55, .7))), 0., 1.);
    vec3 sphere = uDark > .5 ? mix(vColor, vec3(1.), .25 + .7 * lit) : vColor * (.45 + .55 * lit);
    float halo = exp(-d * d * 6.) * (.15 + .5 * uDark);
    col = mix(vColor, sphere, core);
    a = max(core, halo);
  } else {
    // bead or speck
    a = smoothstep(1., .3, d);
    col = mix(vColor, vec3(1.), (1. - vKind * .5) * .3 * uDark);
  }
  a = min(1., a * vAlpha * uAlphaGain);
  if (a < .004) discard;
  gl_FragColor = vec4(col, a);
}
`;

function mulberry32(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function orbitPoint(o: Orbit, t: number, out = new THREE.Vector3()) {
  const a = t * TAU;
  return out.set(Math.cos(a) * o.a, 0, Math.sin(a) * o.b).applyAxisAngle(X, o.rx).applyAxisAngle(Z, o.rz).add(new THREE.Vector3(...o.c));
}

/** alpha of a span list at t, with soft ends */
function spanAlpha(spans: Span[], t: number) {
  let a = 0;
  for (const [from, to, alpha] of spans) {
    const x = (((t - from) % 1) + 1) % 1;
    const len = to - from;
    if (x <= len) a = Math.max(a, alpha * Math.min(1, x / 0.03, (len - x) / 0.03));
  }
  return a;
}

/** point on the band's outer (side -1) or inner (side 1) contour, t in turns */
function contourPoint(t: number, side: number, out = new THREE.Vector3()) {
  const s = t * TAU;
  const phi = ringContour(s, side);
  const rad = RING.R + RING.r * Math.cos(phi);
  return out.set(Math.cos(s) * rad, RING.r * RING.flat * Math.sin(phi), Math.sin(s) * rad);
}

class LineBuilder {
  readonly pos: number[] = [];
  readonly next: number[] = [];
  readonly radial: number[] = [];
  readonly side: number[] = [];
  readonly core: number[] = [];
  readonly glow: number[] = [];
  readonly alpha: number[] = [];
  readonly t: number[] = [];
  readonly glint: number[] = [];
  readonly tint: number[] = [];
  readonly index: number[] = [];

  /** a closed path sampled SAMPLES times; quads whose ends are both invisible are skipped */
  add(point: (t: number) => THREE.Vector3, alpha: (t: number) => number, o: { core: number; glow: number; tint: Tint; glint?: number }) {
    const base = this.side.length;
    for (let i = 0; i <= SAMPLES; i++) {
      const t = i / SAMPLES;
      const p = point(t);
      const n = point(t + 1 / SAMPLES);
      const a = alpha(t);
      for (const side of [-1, 1]) {
        this.pos.push(p.x, p.y, p.z);
        this.next.push(n.x, n.y, n.z);
        this.radial.push(Math.cos(t * TAU), 0, Math.sin(t * TAU));
        this.side.push(side);
        this.core.push(o.core);
        this.glow.push(o.glow);
        this.alpha.push(a);
        this.t.push(t);
        this.glint.push(o.glint ?? 0);
        this.tint.push(...o.tint);
      }
      if (i < SAMPLES && (a > 0 || alpha((i + 1) / SAMPLES) > 0)) {
        const v = base + i * 2;
        this.index.push(v, v + 1, v + 2, v + 1, v + 3, v + 2);
      }
    }
  }

  build() {
    const g = new THREE.BufferGeometry();
    const f = (a: number[], n: number) => new THREE.Float32BufferAttribute(a, n);
    g.setAttribute("position", f(this.pos, 3));
    g.setAttribute("aNext", f(this.next, 3));
    g.setAttribute("aRadial", f(this.radial, 3));
    g.setAttribute("aSide", f(this.side, 1));
    g.setAttribute("aCore", f(this.core, 1));
    g.setAttribute("aGlow", f(this.glow, 1));
    g.setAttribute("aAlpha", f(this.alpha, 1));
    g.setAttribute("aT", f(this.t, 1));
    g.setAttribute("aGlint", f(this.glint, 1));
    g.setAttribute("aTint", f(this.tint, 4));
    g.setIndex(this.index);
    return g;
  }
}

function buildLines() {
  const b = new LineBuilder();
  // the band's glowing edges: a wide soft bloom under a bright core, outer contour (glint 1) and inner (glint 2)
  for (const [side, glint] of [[-1, 1], [1, 2]] as const) {
    const contour = (t: number) => contourPoint(t, side);
    b.add(contour, () => 0.26, { core: 0, glow: 28, tint: [0.8, 0.2, 0, 0], glint });
    b.add(contour, () => 1.15, { core: 1.4, glow: 10, tint: [0.55, 0, 0.1, 0.35], glint });
  }
  for (const o of ORBITS) {
    if (!o.line) continue;
    const { spans, width, tint } = o.line;
    b.add((t) => orbitPoint(o, t), (t) => spanAlpha(spans, t), { core: width, glow: 4, tint });
  }
  return b.build();
}

function buildPoints() {
  const rnd = mulberry32(4663);
  const c: number[] = [];
  const ab: number[] = [];
  const tilt: number[] = [];
  const span: number[] = [];
  const x: number[] = [];
  const speed: number[] = [];
  const size: number[] = [];
  const alpha: number[] = [];
  const kind: number[] = [];
  const tint: number[] = [];
  const push = (o: Pick<Orbit, "c" | "a" | "b" | "rx" | "rz">, p: { from: number; len: number; x: number; speed: number; size: number; alpha: number; kind: number; tint: Tint }) => {
    c.push(...o.c);
    ab.push(o.a, o.b);
    tilt.push(o.rx, o.rz);
    span.push(p.from, p.len);
    x.push(p.x);
    speed.push(p.speed);
    size.push(p.size);
    alpha.push(p.alpha);
    kind.push(p.kind);
    tint.push(...p.tint);
  };

  for (const o of ORBITS) {
    for (const [from, to, a] of o.beads?.spans ?? []) {
      const len = to - from;
      const count = Math.round((len * TAU * (o.a + o.b)) / 2 / o.beads!.gap);
      for (let i = 0; i < count; i++) {
        push(o, { from, len, x: i / count, speed: 0.006, size: o.beads!.size, alpha: a, kind: 0, tint: o.beads!.tint });
      }
    }
    for (const t of o.nodes ?? []) push(o, { from: t, len: 1, x: 0, speed: 0.004, size: 40, alpha: 1, kind: 1, tint: [0.15, 0.3, 0, 0.55] });
  }

  // dust: mostly just outside the torus, thinning outward, a little denser on the near left
  for (let i = 0; i < DUST; i++) {
    const k = rnd();
    const g = Math.abs(rnd() + rnd() + rnd() - 1.5) / 1.5;
    const rho = k < 0.2 ? RING.R + (rnd() - 0.5) * 2 * RING.r : k < 0.88 ? RING.R + RING.r * 0.9 + g * 0.8 : 2.5 + rnd();
    const o = { c: [0, (rnd() - 0.5) * (k < 0.2 ? 0.4 : 0.32), 0] as [number, number, number], a: rho, b: rho, rx: (rnd() - 0.5) * 0.12, rz: (rnd() - 0.5) * 0.12 };
    const at = rnd() < 0.45 ? 0.22 + rnd() * 0.4 : rnd();
    const hue = rnd();
    push(o, {
      from: 0,
      len: 1,
      x: at,
      speed: 0.001 + rnd() * 0.003,
      size: 1.4 + rnd() * 1.9,
      alpha: 0.35 + rnd() * 0.6,
      kind: 2,
      tint: hue < 0.5 ? [0, 0, 1, 0] : hue < 0.85 ? [1, 0, 0, 0] : [0, 1, 0, 0],
    });
  }

  const geo = new THREE.BufferGeometry();
  const f = (a: number[], n: number) => new THREE.Float32BufferAttribute(a, n);
  // position is unused (the shader places every point from its orbit) but three needs it for the draw count
  geo.setAttribute("position", f(new Array(kind.length * 3).fill(0), 3));
  geo.setAttribute("aC", f(c, 3));
  geo.setAttribute("aAB", f(ab, 2));
  geo.setAttribute("aTilt", f(tilt, 2));
  geo.setAttribute("aSpan", f(span, 2));
  geo.setAttribute("aX", f(x, 1));
  geo.setAttribute("aSpeed", f(speed, 1));
  geo.setAttribute("aSize", f(size, 1));
  geo.setAttribute("aAlpha", f(alpha, 1));
  geo.setAttribute("aKind", f(kind, 1));
  geo.setAttribute("aTint", f(tint, 4));
  return geo;
}

/**
 * Builds the orbit layer. `shared` holds the glyph material's uniforms (time, intro, transform, colors, alpha), so both
 * layers move together; the returned `uniforms` are this layer's own (hero weight, pixel size, theme).
 */
export function createRingOrbits(shared: Record<string, THREE.IUniform>) {
  const uniforms = {
    uHero: { value: 0 },
    uHalfRes: { value: new THREE.Vector2(1, 1) },
    uPx: { value: 1 },
    uDark: { value: 1 },
  };
  const all = { ...shared, ...uniforms };
  const material = (vertexShader: string, fragmentShader: string) =>
    new THREE.ShaderMaterial({
      vertexShader,
      fragmentShader,
      uniforms: all,
      transparent: true,
      depthWrite: false,
      depthTest: false,
      blending: THREE.AdditiveBlending,
      side: THREE.DoubleSide, // line strips face either way depending on their screen direction
    });

  const lines = new THREE.Mesh(buildLines(), material(orbitLineVertex, orbitLineFragment));
  const points = new THREE.Points(buildPoints(), material(orbitPointVertex, orbitPointFragment));
  for (const [i, o] of [lines, points].entries()) {
    o.frustumCulled = false;
    o.renderOrder = i + 1;
  }

  return {
    objects: [lines, points] as THREE.Object3D[],
    uniforms,
    setVisible(v: boolean) {
      lines.visible = v;
      points.visible = v;
    },
    setTheme(dark: boolean) {
      uniforms.uDark.value = dark ? 1 : 0;
      for (const m of [lines.material, points.material]) {
        m.blending = dark ? THREE.AdditiveBlending : THREE.NormalBlending;
        m.needsUpdate = true;
      }
    },
    dispose() {
      lines.geometry.dispose();
      points.geometry.dispose();
      lines.material.dispose();
      points.material.dispose();
    },
  };
}
