"use client";

import * as React from "react";
import { useTheme } from "next-themes";
import * as THREE from "three";
import { GLYPH_SETS, RIBBON_SHAPES, ribbonFragment, ribbonVertex } from "./ribbon-shaders";

const ALONG = 240;
const ACROSS = 22;
export const GLYPH_COUNT = ALONG * ACROSS;
const ATLAS_COLS = 16;
const CELL = 64;

/** Per-section camera framing: [yaw, pitch, scale] so every shape reads well. */
const FRAMING: [number, number, number][] = [
  [0.2, 0.55, 1.0], // möbius
  [0.15, 0.35, 1.0], // router
  [0.25, 0.3, 0.95], // wave
  [-0.35, 0.18, 0.95], // bins
  [0.3, 0.25, 1.0], // spiral
  [0.35, 0.2, 0.95], // helix
  [0.1, 0.75, 1.0], // vortex
  [0.25, 0.45, 0.95], // knot
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

function buildAtlas(): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = ATLAS_COLS * CELL;
  canvas.height = RIBBON_SHAPES * CELL;
  const ctx = canvas.getContext("2d")!;
  const mono = getComputedStyle(document.body).getPropertyValue("--font-geist-mono").trim() || "ui-monospace";
  ctx.font = `500 ${CELL * 0.72}px ${mono}, ui-monospace, monospace`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillStyle = "#fff";
  GLYPH_SETS.forEach((set, row) => {
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
  onFrame,
  className,
}: {
  sectionRef: React.RefObject<number>;
  onFrame?: (f: RibbonFrame) => void;
  className?: string;
}) {
  const hostRef = React.useRef<HTMLDivElement>(null);
  const materialRef = React.useRef<THREE.ShaderMaterial | null>(null);
  const onFrameRef = React.useRef(onFrame);
  const { resolvedTheme } = useTheme();

  React.useEffect(() => {
    onFrameRef.current = onFrame;
  }, [onFrame]);

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
        uScale: { value: 1 },
        uOffset: { value: new THREE.Vector3() },
        uMouse: { value: new THREE.Vector2(9, 9) },
        uMouseActive: { value: 0 },
        uPulseOrigin: { value: new THREE.Vector2() },
        uPulseAge: { value: -1 },
        uAspect: { value: 1 },
        uGlyphSize: { value: 0.085 },
        uAtlas: { value: buildAtlas() },
        uAtlasGrid: { value: new THREE.Vector2(ATLAS_COLS, RIBBON_SHAPES) },
        uColorA: { value: new THREE.Color() },
        uColorB: { value: new THREE.Color() },
        uColorC: { value: new THREE.Color() },
        uColorHot: { value: new THREE.Color() },
        uGlobalAlpha: { value: 1 },
      },
    });
    materialRef.current = material;
    const mesh = new THREE.Mesh(geometry, material);
    mesh.frustumCulled = false;
    scene.add(mesh);

    // fonts may arrive after first paint: rebuild the atlas once they are ready
    void document.fonts?.ready.then(() => {
      const old = material.uniforms.uAtlas!.value as THREE.Texture;
      material.uniforms.uAtlas!.value = buildAtlas();
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
    let yaw = FRAMING[0]![0];
    let pitch = FRAMING[0]![1];
    let scale = FRAMING[0]![2];
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
      const target = Math.max(0, Math.min(RIBBON_SHAPES - 1, sectionRef.current ?? 0));
      section += (target - section) * (reduce ? 1 : ease(5, dt));
      const a = Math.floor(section);
      const b = Math.min(RIBBON_SHAPES - 1, a + 1);
      const k = section - a;
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
      const sway = reduce ? 0 : Math.sin(t * 0.17) * 0.45;
      const tYaw = fa[0] + (fb[0] - fa[0]) * k + sway + mouse.x * mouse.active * 0.55;
      const tPitch = fa[1] + (fb[1] - fa[1]) * k - mouse.y * mouse.active * 0.3;
      yaw += (tYaw - yaw) * ease(3, dt);
      pitch += (tPitch - pitch) * ease(3, dt);
      scale += (fa[2] + (fb[2] - fa[2]) * k - scale) * ease(3, dt);
      offX += ((wide ? 2.05 : 0) - offX) * ease(5, dt);
      u.uYaw!.value = yaw;
      u.uPitch!.value = pitch;
      u.uScale!.value = scale * (wide ? 1 : 0.8);
      u.uOffset!.value.set(offX, wide ? 0 : 0.35, 0);
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
      renderer.dispose();
      renderer.domElement.remove();
      materialRef.current = null;
    };
  }, [sectionRef]);

  // theme: colors from the design tokens; additive light on dark, normal blending on light
  React.useEffect(() => {
    const m = materialRef.current;
    if (!m) return;
    const s = getComputedStyle(document.documentElement);
    const dark = resolvedTheme !== "light";
    m.uniforms.uColorA!.value.copy(rgbVar(s, dark ? "--primary" : "--primary-text", [134, 246, 31]));
    m.uniforms.uColorB!.value.copy(rgbVar(s, dark ? "--accent" : "--accent-text", [46, 211, 183]));
    m.uniforms.uColorC!.value.copy(rgbVar(s, "--warning", [245, 181, 61]));
    m.uniforms.uColorHot!.value.copy(dark ? rgbVar(s, "--primary-200", [208, 251, 161]) : rgbVar(s, "--text", [18, 18, 17]));
    m.blending = dark ? THREE.AdditiveBlending : THREE.NormalBlending;
    m.needsUpdate = true;
  }, [resolvedTheme]);

  return <div ref={hostRef} className={className} aria-hidden />;
}
