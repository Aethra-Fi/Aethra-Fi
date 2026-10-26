// GLSL for the landing glyph ribbon. Every glyph is an instanced billboard placed on a parametric ribbon
// surface at (u along the ribbon, v across it). Each landing section has its own surface; the vertex shader
// evaluates the current and the next surface and morphs between them, so the ribbon reshapes continuously
// while the page scrolls sideways.
//
// Shapes: 0 Möbius loop · 1 router figure-eight · 2 volatility wave · 3 DLMM bin histogram
//         4 bonding-curve spiral · 5 collateral/debt double helix · 6 burn vortex · 7 torus knot

export const RIBBON_SHAPES = 8;

export const ribbonVertex = /* glsl */ `
#define PI 3.14159265
#define TAU 6.28318530

attribute vec2 aParam;   // u in [0,1] along, v in [-1,1] across
attribute float aSeed;   // 0..1 per glyph

uniform float uTime;
uniform float uShapeA;
uniform float uShapeB;
uniform float uMix;
uniform float uIntro;
uniform float uYaw;
uniform float uPitch;
uniform float uScale;
uniform vec3 uOffset;
uniform vec2 uMouse;
uniform float uMouseActive;
uniform vec2 uPulseOrigin;
uniform float uPulseAge;
uniform float uAspect;
uniform float uGlyphSize;
uniform vec2 uAtlasGrid;
uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;
uniform vec3 uColorHot;
uniform float uGlobalAlpha;

varying vec2 vUv;
varying vec3 vColor;
varying float vAlpha;

float hash(float n) { return fract(sin(n) * 43758.5453123); }

mat3 rotY(float a) { float c = cos(a), s = sin(a); return mat3(c, 0., -s, 0., 1., 0., s, 0., c); }
mat3 rotX(float a) { float c = cos(a), s = sin(a); return mat3(1., 0., 0., 0., c, s, 0., -s, c); }

// offset from a centerline point across the ribbon, twisted by tw around the tangent
vec3 across(vec3 c0, vec3 c1, float w, float tw) {
  vec3 T = normalize(c1 - c0 + 1e-5);
  vec3 up = abs(T.y) > 0.95 ? vec3(1., 0., 0.) : vec3(0., 1., 0.);
  vec3 B = normalize(cross(T, up));
  vec3 N = cross(B, T);
  return (N * cos(tw) + B * sin(tw)) * w;
}

vec3 cMobius(float s) { return vec3(cos(s) * 1.55, sin(s * 2.) * 0.14, sin(s) * 1.55); }
vec3 cRouter(float s) { return vec3(sin(s) * 2.15, sin(2. * s) * 0.78, cos(s) * 0.6); }
vec3 cWave(float s) {
  float x = (s / TAU - .5) * 5.8;
  float vol = .55 + .45 * sin(uTime * .7 + x * .8);
  return vec3(x, sin(x * 1.7 - uTime * 1.5) * .5 * vol, cos(x * 1.1 + uTime * .6) * .4);
}
vec3 cSpiral(float s) {
  float u = s / TAU;
  float a = u * 5. * PI + uTime * .25;
  float r = .22 + 1.4 * u;
  return vec3(cos(a) * r, -1.55 + 3. * pow(u, 1.7), sin(a) * r);
}
vec3 cVortex(float s) {
  float u = s / TAU;
  float a = u * 7. * PI + uTime * .9;
  float r = 2.15 * pow(1. - u, 1.3) + .04;
  return vec3(cos(a) * r, .95 - u * 2. + sin(a * .5) * .08, sin(a) * r);
}
vec3 cKnot(float s) {
  float r = 2. + cos(3. * s);
  return vec3(r * cos(2. * s), r * sin(2. * s), sin(3. * s)) * .62;
}

vec3 ribbon(int k, float u, float v, out float fade) {
  fade = 1.;
  float s = u * TAU;
  float e = .002 * TAU;
  if (k == 0) return cMobius(s) + across(cMobius(s), cMobius(s + e), .58 * v, s * .5 + uTime * .15);
  if (k == 1) return cRouter(s) + across(cRouter(s), cRouter(s + e), .34 * v, s + uTime * .3);
  if (k == 2) return cWave(s) + across(cWave(s), cWave(s + e), .55 * v, s * 1.5 + sin(uTime * .6) * .6);
  if (k == 3) {
    // a histogram of liquidity bins: glyph columns with gaps, taller near the active bin
    float n = 23.;
    float i = floor(u * n);
    float f = fract(u * n);
    float d = (i - 11. + sin(uTime * .35) * 2.) / 5.;
    float h = (exp(-d * d) * 2. + .14) * (1. + .1 * sin(uTime * 1.3 + i * .7));
    fade = step(.14, f) * step(f, .86);
    return vec3((i / (n - 1.) - .5) * 4.7 + (f - .5) * .16, -1.05 + (v * .5 + .5) * h, (hash(i * 13.1 + floor(f * 3.)) - .5) * .3);
  }
  if (k == 4) return cSpiral(s) + across(cSpiral(s), cSpiral(s + e), (.12 + .4 * u) * v, s * 2.);
  if (k == 5) {
    // two strands (collateral and debt) wound around the same axis
    float strand = v < 0. ? 0. : PI;
    float w = abs(v) * 2. - 1.;
    float a = u * 4. * PI + uTime * .35 + strand;
    vec3 c = vec3((u - .5) * 5.4, cos(a) * .9, sin(a) * .9);
    vec3 c1 = vec3((u + .002 - .5) * 5.4, cos(a + .0251) * .9, sin(a + .0251) * .9);
    return c + across(c, c1, .15 * w, a);
  }
  if (k == 6) {
    fade = 1. - smoothstep(.72, 1., u);
    return cVortex(s) + across(cVortex(s), cVortex(s + e), .45 * (1. - u) * v, s * 3.);
  }
  return cKnot(s) + across(cKnot(s), cKnot(s + e), .3 * v, s * 3. + uTime * .2);
}

vec3 shapeColor(int k, float u, float v) {
  if (k == 3) return u < .5 ? uColorB : uColorA;                 // token1 below the active bin, token0 above
  if (k == 5) return v < 0. ? uColorA : uColorB;                 // collateral vs debt strands
  if (k == 6) return mix(uColorA, uColorC, smoothstep(.15, .85, u)); // burns toward amber at the core
  return mix(uColorA, uColorB, .5 + .5 * sin(u * TAU + uTime * .3));
}

void main() {
  float u = aParam.x;
  float v = aParam.y;
  int ka = int(uShapeA);
  int kb = int(uShapeB);
  float fa;
  float fb;
  vec3 pa = ribbon(ka, u, v, fa);
  vec3 pb = ribbon(kb, u, v, fb);

  // staggered morph: every glyph leaves at a slightly different moment, and lifts off the surface mid-flight
  float m = clamp((uMix - aSeed * .3) / .7, 0., 1.);
  m = m * m * (3. - 2. * m);
  vec3 scatter = vec3(hash(aSeed * 7.1) - .5, hash(aSeed * 11.3) - .5, hash(aSeed * 17.7) - .5);
  vec3 p = mix(pa, pb, m) + scatter * sin(m * PI) * 1.3;
  float fade = mix(fa, fb, m);

  // intro: glyphs condense out of a wide cloud
  float intro = smoothstep(0., 1., clamp(uIntro * 1.4 - aSeed * .4, 0., 1.));
  p = mix(scatter * 9., p, intro);

  p = rotY(uYaw) * rotX(uPitch) * p * uScale + uOffset;
  vec4 mv = modelViewMatrix * vec4(p, 1.);
  vec4 clip = projectionMatrix * mv;
  vec2 ndc = clip.xy / clip.w;

  // cursor: glyphs within reach are pushed aside, grow, heat up and scramble faster
  vec2 dm = (ndc - uMouse) * vec2(uAspect, 1.);
  float hover = uMouseActive * smoothstep(.34, 0., length(dm));
  float ring = 0.;
  if (uPulseAge >= 0.) {
    vec2 dp = (ndc - uPulseOrigin) * vec2(uAspect, 1.);
    ring = exp(-pow((length(dp) - uPulseAge * 1.7) * 8., 2.)) * (1. - smoothstep(0., 1.5, uPulseAge));
  }
  mv.xy += normalize(dm + 1e-4) * hover * .38;
  mv.z += ring * .7 + hover * .35;

  float size = uGlyphSize * (1. + hover * 1.5 + ring * 1.3) * (.65 + .35 * hash(aSeed * 3.3));
  mv.xy += position.xy * size;
  gl_Position = projectionMatrix * mv;

  // each section has its own glyph set (atlas row); the set flips per glyph during the morph
  float rate = .35 + aSeed * 1.5 + hover * 24. + ring * 24.;
  float tick = floor(uTime * rate + aSeed * 100.);
  float row = m < .5 ? float(ka) : float(kb);
  float col = floor(hash(aSeed * 91.7 + tick) * uAtlasGrid.x);
  vUv = (vec2(col, uAtlasGrid.y - 1. - row) + uv) / uAtlasGrid;

  float edge = smoothstep(.5, 1., abs(v));
  vec3 color = mix(shapeColor(ka, u, v), shapeColor(kb, u, v), m);
  vColor = mix(color, uColorHot, clamp(hover * .85 + ring * .7, 0., 1.));
  float depthFade = smoothstep(10., 3.4, -mv.z);
  vAlpha = uGlobalAlpha * fade * intro * depthFade * clamp(.32 + .68 * edge + hover + ring, 0., 1.6);
}
`;

export const ribbonFragment = /* glsl */ `
uniform sampler2D uAtlas;
uniform float uAlphaGain;
varying vec2 vUv;
varying vec3 vColor;
varying float vAlpha;

void main() {
  float a = min(1., texture2D(uAtlas, vUv).a * vAlpha * uAlphaGain);
  if (a < .02) discard;
  gl_FragColor = vec4(vColor, a);
}
`;

/** Glyph set per shape (16 each), one atlas row per section. */
export const GLYPH_SETS = [
  "·:+×◇○◆□01ΛΞΣ∴∷#",
  "→←↗↘⇢⇄⟶↔⇉⤳>~·:↦⇥",
  "∿≈~%∆δσ±·:+12345",
  "▁▂▃▄▅▆▇█▏▎▍▌|¦:·",
  "↑⇡▲△^$⌃*+·:01ΔΣ∫",
  "⊕⊗∞∾≡=¤$%·:+×◇○∥",
  "░▒▓█*·'.`^×+:;~,",
  "{}<>/=;()[]$#_01",
];
