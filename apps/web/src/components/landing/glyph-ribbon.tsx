"use client";

import * as React from "react";
import { useTheme } from "next-themes";
import * as THREE from "three";
import { GLYPH_SETS, RIBBON_SHAPES, RING, ribbonFragment, ribbonVertex } from "./ribbon-shaders";
import { createRingOrbits } from "./ring-orbits";

const ALONG = 240;
const ACROSS = 22;
export const GLYPH_COUNT = ALONG * ACROSS;
const ATLAS_COLS = 16;
const CELL = 64;

interface Framing {
  yaw: number;
  pitch: number;
  /** on-screen tilt */
  roll: number;
  scale: number;
  /** scales the idle and pointer swing: a tilted ring turns into a steep diagonal under the full swing */
  sway: number;
  /** horizontal offset on wide screens */
  x: number;
  /** depth squeeze (1 = the camera's own perspective) */
  depth: number;
}

const framing = (yaw: number, pitch: number, scale: number): Framing => ({ yaw, pitch, scale, roll: 0, sway: 1, x: 2.05, depth: 1 });

/** Per-section camera framing so every shape reads well. */
const FRAMING: Framing[] = [
  // liquidity ring: seen from above, tilted, with a long lens so the front wall doesn't balloon
  { yaw: -0.06, pitch: RING.pitch, roll: RING.roll, scale: 0.94, sway: 0.15, x: 1.85, depth: 0.4 },
  framing(0.15, 0.35, 1.0), // router
  framing(0.25, 0.3, 0.95), // wave
  framing(-0.35, 0.18, 0.95), // bins
  framing(0.3, 0.25, 1.0), // spiral
  framing(0.35, 0.2, 0.95), // helix
  framing(0.1, 0.75, 1.0), // vortex
  framing(0.25, 0.45, 0.95), // knot
];

export interface RibbonFrame {
  /** cursor position in ribbon space (rough, for the HUD) */
  x: number;
  y: number;
  /** continuous section position, e.g. 2.4 = 40% from section 2 to 3 */
  section: number;
  /** whether the cursor is over the ribbon area */
  active: boolean;
}

function rgbVar(styles: CSSStyleDeclaration, name: string, fallback: [number, number, number]) {
  const parts = styles.getPropertyValue(name).trim().split(/\s+/).map(Number);
  const [r, g, b] = (parts.length === 3 && parts.every((n) => Number.isFinite(n)) ? parts : fallback) as [number, number, number];
  return new THREE.Color(r / 255, g / 255, b / 255);
}

/**
 * The ring's glyph set (atlas row 0): chips with a dim fill and a bright outline, like shards of a circuit, plus
 * squares, brackets, a dot and a ring. Seeded, so the set is the same on every load.
 */
function drawRingChips(ctx: CanvasRenderingContext2D, row: number, line: number) {
  let seed = 46630;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) - 1) / 2147483646;
  const shape = (draw: () => void, fill: number) => {
    ctx.beginPath();
    draw();
    ctx.globalAlpha = fill;
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.stroke();
  };
  const polyline = (pts: [number, number][]) => () =>
    pts.forEach(([x, y], i) => (i ? ctx.lineTo(x * CELL, y * CELL) : ctx.moveTo(x * CELL, y * CELL)));
  ctx.lineWidth = line;
  ctx.lineJoin = "round";
  ctx.strokeStyle = "#fff";
  for (let col = 0; col < ATLAS_COLS; col++) {
    ctx.save();
    ctx.translate(col * CELL + CELL / 2, row * CELL + CELL / 2);
    if (col < 10) {
      const k = 4 + Math.floor(rnd() * 3);
      const squash = 0.6 + rnd() * 0.5;
      shape(() => {
        for (let i = 0; i < k; i++) {
          const a = ((i + rnd() * 0.6) / k) * Math.PI * 2;
          const r = CELL * (0.2 + rnd() * 0.17);
          ctx.lineTo(Math.cos(a) * r, Math.sin(a) * r * squash);
        }
        ctx.closePath();
      }, 0.25);
    } else if (col === 10) shape(() => ctx.rect(-CELL * 0.2, -CELL * 0.2, CELL * 0.4, CELL * 0.4), 0.3);
    else if (col === 11) shape(() => ctx.rect(-CELL * 0.17, -CELL * 0.17, CELL * 0.34, CELL * 0.34), 1);
    else if (col === 12) shape(polyline([[-0.22, -0.25], [-0.22, 0.2], [0.25, 0.2]]), 0);
    else if (col === 13) shape(polyline([[-0.25, -0.1], [0.15, -0.1], [0.15, 0.22]]), 0);
    else if (col === 14) shape(() => ctx.arc(0, 0, CELL * 0.12, 0, Math.PI * 2), 1);
    else shape(() => ctx.arc(0, 0, CELL * 0.24, 0, Math.PI * 2), 0.25);
    ctx.restore();
  }
}

/** Light theme draws dark ink on a pale page, so it needs heavier strokes than additive light on dark. */
function buildAtlas(weight = 500): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = ATLAS_COLS * CELL;
  canvas.height = RIBBON_SHAPES * CELL;
  const ctx = canvas.getContext("2d")!;
  const mono = getComputedStyle(document.body).getPropertyValue("--font-geist-mono").trim() || "ui-monospace";
  ctx.font = `${weight} ${CELL * 0.72}px ${mono}, ui-monospace, monospace`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillStyle = "#fff";
  GLYPH_SETS.forEach((set, row) => {
    if (set === null) return drawRingChips(ctx, row, weight > 600 ? 9 : 7);
    const glyphs = Array.from(set);
    for (let col = 0; col < ATLAS_COLS; col++) {
      ctx.fillText(glyphs[col % glyphs.length]!, col * CELL + CELL / 2, row * CELL + CELL / 2 + 2);
    }
  });
  const tex = new THREE.CanvasTexture(canvas);
  tex.minFilter = THREE.LinearMipmapLinearFilter;
  tex.anisotropy = 4;
  return tex;
}

/**
 * The landing's 3D glyph ribbon. Reads the horizontal scroll position from `sectionRef` every frame and
 * morphs between the section shapes; reports the cursor and morph state through `onFrame` for the HUD.
 */
export function GlyphRibbon({
  sectionRef,
  shapes,
  onFrame,
  className,
}: {
  sectionRef: React.RefObject<number>;
  /** ribbon shape per landing section; defaults to one shape per section in order */
  shapes?: number[];
  onFrame?: (f: RibbonFrame) => void;
  className?: string;
}) {
  const hostRef = React.useRef<HTMLDivElement>(null);
  const materialRef = React.useRef<THREE.ShaderMaterial | null>(null);
  const orbitsRef = React.useRef<ReturnType<typeof createRingOrbits> | null>(null);
  const onFrameRef = React.useRef(onFrame);
  const shapesKey = (shapes ?? []).join(",");
  const shapesRef = React.useRef<number[]>(shapes ?? []);
  const { resolvedTheme } = useTheme();
  const atlasWeightRef = React.useRef(500);

  React.useEffect(() => {
    onFrameRef.current = onFrame;
  }, [onFrame]);

  React.useEffect(() => {
    shapesRef.current = shapesKey ? shapesKey.split(",").map(Number) : [];
  }, [shapesKey]);

  // scene setup, once
  React.useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    let renderer: THREE.WebGLRenderer;
    try {
      renderer = new THREE.WebGLRenderer({ alpha: true, antialias: false, powerPreference: "high-performance" });
    } catch {
      return; // no WebGL: the page still works, just without the ribbon
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
    renderer.setClearColor(0x000000, 0);
    host.appendChild(renderer.domElement);
    renderer.domElement.style.width = "100%";
    renderer.domElement.style.height = "100%";

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 60);
    camera.position.set(0, 0, 6.4);

    // instanced glyph quads
    const geometry = new THREE.InstancedBufferGeometry();
    const quad = new THREE.PlaneGeometry(1, 1);
    geometry.index = quad.index;
    geometry.setAttribute("position", quad.getAttribute("position"));
    geometry.setAttribute("uv", quad.getAttribute("uv"));
    const params = new Float32Array(GLYPH_COUNT * 2);
    const seeds = new Float32Array(GLYPH_COUNT);
    let n = 0;
    for (let i = 0; i < ALONG; i++) {
      for (let j = 0; j < ACROSS; j++) {
        params[n * 2] = (i + Math.random() * 0.35) / ALONG;
        params[n * 2 + 1] = -1 + (2 * j) / (ACROSS - 1);
        seeds[n] = Math.random();
        n++;
      }
    }
    geometry.setAttribute("aParam", new THREE.InstancedBufferAttribute(params, 2));
    geometry.setAttribute("aSeed", new THREE.InstancedBufferAttribute(seeds, 1));
    geometry.instanceCount = GLYPH_COUNT;

    const material = new THREE.ShaderMaterial({
      vertexShader: ribbonVertex,
      fragmentShader: ribbonFragment,
      transparent: true,
      depthWrite: false,
      depthTest: false,
      blending: THREE.AdditiveBlending,
      uniforms: {
        uTime: { value: 0 },
        uShapeA: { value: 0 },
        uShapeB: { value: 0 },
        uMix: { value: 0 },
        uIntro: { value: reduce ? 1 : 0 },
        uYaw: { value: 0 },
        uPitch: { value: 0.5 },
        uRoll: { value: 0 },
        uScale: { value: 1 },
        uDepth: { value: 1 },
        uOffset: { value: new THREE.Vector3() },
        uMouse: { value: new THREE.Vector2(9, 9) },
        uMouseActive: { value: 0 },
        uPulseOrigin: { value: new THREE.Vector2() },
        uPulseAge: { value: -1 },
        uAspect: { value: 1 },
        uGlyphSize: { value: 0.085 },
        uAtlas: { value: buildAtlas(atlasWeightRef.current) },
        uAtlasGrid: { value: new THREE.Vector2(ATLAS_COLS, RIBBON_SHAPES) },
        uColorA: { value: new THREE.Color() },
        uColorB: { value: new THREE.Color() },
        uColorC: { value: new THREE.Color() },
        uColorHot: { value: new THREE.Color() },
        uGlobalAlpha: { value: 1 },
        uAlphaGain: { value: 1 },
      },
    });
    materialRef.current = material;
    const mesh = new THREE.Mesh(geometry, material);
    mesh.frustumCulled = false;
    scene.add(mesh);

    // the hero ring's orbits, nodes, dust and edge glow, moving with the glyphs through the shared uniforms
    const orbits = createRingOrbits(material.uniforms);
    orbitsRef.current = orbits;
    scene.add(...orbits.objects);

    // fonts may arrive after first paint: rebuild the atlas once they are ready
    void document.fonts?.ready.then(() => {
      const old = material.uniforms.uAtlas!.value as THREE.Texture;
      material.uniforms.uAtlas!.value = buildAtlas(atlasWeightRef.current);
      old.dispose();
    });

    let width = 1;
    let height = 1;
    let wide = true;
    const resize = () => {
      const r = host.getBoundingClientRect();
      width = Math.max(1, r.width);
      height = Math.max(1, r.height);
      wide = width >= 1024;
      renderer.setSize(width, height, false);
      camera.aspect = width / height;
      camera.updateProjectionMatrix();
      material.uniforms.uAspect!.value = camera.aspect;
      material.uniforms.uGlyphSize!.value = wide ? 0.085 : 0.07;
      material.uniforms.uGlobalAlpha!.value = wide ? 1 : 0.55;
      const px = renderer.getPixelRatio();
      orbits.uniforms.uPx.value = px;
      orbits.uniforms.uHalfRes.value.set((width * px) / 2, (height * px) / 2);
    };
    const ro = new ResizeObserver(resize);
    ro.observe(host);
    resize();

    const clock = new THREE.Clock();

    // pointer: tracked on the window so the ribbon reacts through the text layer above it
    const mouse = { x: 9, y: 9, tx: 9, ty: 9, active: 0, tactive: 0 };
    const onMove = (e: PointerEvent) => {
      const r = host.getBoundingClientRect();
      mouse.tx = ((e.clientX - r.left) / r.width) * 2 - 1;
      mouse.ty = -(((e.clientY - r.top) / r.height) * 2 - 1);
      mouse.tactive = e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom ? 1 : 0;
    };
    const onLeave = () => (mouse.tactive = 0);
    let pulseStart = -1;
    const onDown = (e: PointerEvent) => {
      if (reduce) return;
      const r = host.getBoundingClientRect();
      if (e.clientY < r.top || e.clientY > r.bottom) return;
      material.uniforms.uPulseOrigin!.value.set(((e.clientX - r.left) / r.width) * 2 - 1, -(((e.clientY - r.top) / r.height) * 2 - 1));
      pulseStart = clock.getElapsedTime();
    };
    window.addEventListener("pointermove", onMove, { passive: true });
    window.addEventListener("pointerdown", onDown, { passive: true });
    document.addEventListener("pointerleave", onLeave);

    let section = sectionRef.current ?? 0;
    let { yaw, pitch, scale, roll, depth } = FRAMING[0]!;
    let offX = 0;
    let raf = 0;
    let last = 0;
    const timeScale = reduce ? 0.12 : 1;
    // frame-rate independent easing: same feel at 30 fps and 144 fps
    const ease = (rate: number, dt: number) => 1 - Math.exp(-rate * dt);

    const frame = () => {
      raf = requestAnimationFrame(frame);
      if (document.hidden) return;
      const t = clock.getElapsedTime();
      const dt = Math.min(0.1, t - last);
      last = t;
      const u = material.uniforms;
      u.uTime!.value = t * timeScale;
      if (!reduce) u.uIntro!.value = Math.min(1, t / 2.2);

      // follow the scroll position with a little lag so fast swipes still read as a morph
      const map = shapesRef.current;
      const lastSection = (map.length || RIBBON_SHAPES) - 1;
      const target = Math.max(0, Math.min(lastSection, sectionRef.current ?? 0));
      section += (target - section) * (reduce ? 1 : ease(5, dt));
      const sa = Math.min(lastSection, Math.floor(section));
      const sb = Math.min(lastSection, sa + 1);
      const k = section - sa;
      const a = map[sa] ?? sa;
      const b = map[sb] ?? sb;
      u.uShapeA!.value = a;
      u.uShapeB!.value = b;
      u.uMix!.value = k;

      mouse.x += (mouse.tx - mouse.x) * ease(8, dt);
      mouse.y += (mouse.ty - mouse.y) * ease(8, dt);
      mouse.active += (mouse.tactive - mouse.active) * ease(5, dt);
      u.uMouse!.value.set(mouse.x, mouse.y);
      u.uMouseActive!.value = mouse.active;

      const fa = FRAMING[a]!;
      const fb = FRAMING[b]!;
      const lerp = (key: keyof Framing) => fa[key] + (fb[key] - fa[key]) * k;
      const swing = lerp("sway");
      const sway = reduce ? 0 : Math.sin(t * 0.17) * 0.45;
      const tYaw = lerp("yaw") + (sway + mouse.x * mouse.active * 0.55) * swing;
      const tPitch = lerp("pitch") - mouse.y * mouse.active * 0.3 * (0.4 + 0.6 * swing);
      yaw += (tYaw - yaw) * ease(3, dt);
      pitch += (tPitch - pitch) * ease(3, dt);
      roll += (lerp("roll") - roll) * ease(3, dt);
      scale += (lerp("scale") - scale) * ease(3, dt);
      depth += (lerp("depth") - depth) * ease(3, dt);
      offX += ((wide ? lerp("x") : 0) - offX) * ease(5, dt);
      u.uYaw!.value = yaw;
      u.uPitch!.value = pitch;
      u.uRoll!.value = roll;
      u.uDepth!.value = depth;
      u.uScale!.value = scale * (wide ? 1 : 0.8);

      // the orbit layer belongs to the ring: it leaves early in a morph away from it and returns late. On narrow
      // screens the ring sits behind the headline instead of the body copy, with its bright edges toned down.
      const ringWeight = (a === 0 ? 1 - k : 0) + (b === 0 ? k : 0);
      const hero = Math.max(0, 1 - (1 - ringWeight) * 2.5);
      orbits.uniforms.uHero.value = hero * hero * (3 - 2 * hero) * (wide ? 1 : 0.7);
      orbits.setVisible(hero > 0.002);
      u.uOffset!.value.set(offX, wide ? 0 : 0.35 + 0.5 * ringWeight, 0);
      u.uPulseAge!.value = pulseStart < 0 ? -1 : t - pulseStart;
      if (pulseStart >= 0 && t - pulseStart > 1.6) pulseStart = -1;

      renderer.render(scene, camera);
      onFrameRef.current?.({ x: mouse.x * 3.2, y: mouse.y * 1.8, section, active: mouse.tactive === 1 });
    };
    frame();

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerdown", onDown);
      document.removeEventListener("pointerleave", onLeave);
      (material.uniforms.uAtlas!.value as THREE.Texture).dispose();
      geometry.dispose();
      quad.dispose();
      material.dispose();
      orbits.dispose();
      renderer.dispose();
      renderer.domElement.remove();
      materialRef.current = null;
      orbitsRef.current = null;
    };
  }, [sectionRef]);

  // theme: colors from the design tokens. Dark: additive light, overlaps glow. Light: normal blending, so
  // overlaps don't build up; compensate with deeper ink, a bolder atlas and a higher alpha gain.
  React.useEffect(() => {
    const m = materialRef.current;
    if (!m) return;
    const s = getComputedStyle(document.documentElement);
    const dark = resolvedTheme !== "light";
    m.uniforms.uColorA!.value.copy(dark ? rgbVar(s, "--primary", [134, 246, 31]) : rgbVar(s, "--primary-800", [51, 104, 16]));
    m.uniforms.uColorB!.value.copy(rgbVar(s, dark ? "--accent" : "--accent-text", [46, 211, 183]));
    m.uniforms.uColorC!.value.copy(rgbVar(s, "--warning", [245, 181, 61]));
    m.uniforms.uColorHot!.value.copy(dark ? rgbVar(s, "--primary-200", [208, 251, 161]) : rgbVar(s, "--text", [18, 18, 17]));
    m.uniforms.uAlphaGain!.value = dark ? 1 : 2.4;
    const weight = dark ? 500 : 700;
    if (weight !== atlasWeightRef.current) {
      atlasWeightRef.current = weight;
      const old = m.uniforms.uAtlas!.value as THREE.Texture;
      m.uniforms.uAtlas!.value = buildAtlas(weight);
      old.dispose();
    }
    m.blending = dark ? THREE.AdditiveBlending : THREE.NormalBlending;
    m.needsUpdate = true;
    orbitsRef.current?.setTheme(dark);
  }, [resolvedTheme]);

  return <div ref={hostRef} className={className} aria-hidden />;
}
