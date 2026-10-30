// GLSL for the landing glyph ribbon. Every glyph is an instanced billboard placed on a parametric ribbon
// surface at (u along the ribbon, v across it). Each landing section has its own surface; the vertex shader
// evaluates the current and the next surface and morphs between them, so the ribbon reshapes continuously
// while the page scrolls sideways.
//
// Shapes: 0 liquidity ring · 1 router figure-eight · 2 volatility wave · 3 DLMM bin histogram
//         4 bonding-curve spiral · 5 collateral/debt double helix · 6 burn vortex · 7 torus knot

export const RIBBON_SHAPES = 8;

/**
 * The liquidity ring (shape 0) in ribbon units: a thick torus framed from above at `pitch` and rolled on screen by
 * `roll` (right side up). Shared by the glyph shader and the orbit layer (ring-orbits.ts), which draw the same torus.
 */
export const RING = {
  /** major radius */
  R: 1.5,
  /** tube radius, across the ring */
  r: 0.42,
  /** tube height as a share of its width: a flat, wide band rather than a round tube */
  flat: 0.55,
  /** camera elevation the ring is framed at, radians */
  pitch: 0.38,
  /** on-screen tilt, radians */
  roll: 0.34,
};

/**
 * Tube angle (0 points outward, PI/2 straight up) of the band's outer (side -1) or inner (side 1) contour at ring
 * angle s, seen from the framing pitch: the glowing edge lines run there, just inside the silhouette.
 */
export const ringContour = (s: number, side: number) =>
  Math.atan2(Math.sin(RING.pitch), RING.flat * Math.sin(s) * Math.cos(RING.pitch)) + side * (Math.PI / 2 - 0.1);

// Shared by every layer of the ribbon: the section framing (yaw, pitch, roll, scale, offset) as one transform.
export const ribbonTransform = /* glsl */ `
#define PI 3.14159265
#define TAU 6.28318530
#define RING_R ${RING.R.toFixed(4)}
#define RING_TUBE ${RING.r.toFixed(4)}
#define RING_FLAT ${RING.flat.toFixed(4)}
#define RING_PITCH ${RING.pitch.toFixed(4)}

uniform float uYaw;
uniform float uPitch;
uniform float uRoll;
uniform float uScale;
uniform float uDepth;
uniform vec3 uOffset;

mat3 rotY(float a) { float c = cos(a), s = sin(a); return mat3(c, 0., -s, 0., 1., 0., s, 0., c); }
mat3 rotX(float a) { float c = cos(a), s = sin(a); return mat3(1., 0., 0., 0., c, s, 0., -s, c); }
mat3 rotZ(float a) { float c = cos(a), s = sin(a); return mat3(c, s, 0., -s, c, 0., 0., 0., 1.); }
mat3 frameRot() { return rotZ(uRoll) * rotY(uYaw) * rotX(uPitch); }
// uDepth < 1 squeezes depth toward the shape's centre: a longer lens, so a wide shape keeps its proportions
vec3 toFrame(vec3 p) {
  vec3 q = frameRot() * p * uScale;
  q.z *= uDepth;
  return q + uOffset;
}

// How much light a point of the ring catches, by where it sits around the ring on screen (dir: its radial direction
// in view space, xy normalized): the left flank and the far top right glint, the near right stays darker.
float ringGlint(vec2 dir) {
  float left = smoothstep(.1, -.85, dir.x);
  float hot = smoothstep(.45, .95, dot(dir, vec2(.75, .66)));
  return .5 + .65 * left + .9 * hot;
}
// Brightness of the two contour lines. The outer one is lit along the far side and down the left flank, and fades
// out along the near bottom edge; the inner one (the near edge of the hole) is lit in front, most on the left.
float ringContourGain(vec2 dir, float outer) {
  float hot = smoothstep(.45, .95, dot(dir, vec2(.75, .66)));
  float o = (.08 + .95 * max(smoothstep(-.3, .4, dir.y), smoothstep(-.2, -.85, dir.x) * smoothstep(-.5, -.2, dir.y))) * (.8 + .5 * hot);
  float i = .06 + smoothstep(.1, -.6, dir.y) * (.5 + .5 * smoothstep(.7, -.5, dir.x));
  return mix(i, o, outer);
}
`;

export const ribbonVertex = /* glsl */ `
${ribbonTransform}

attribute vec2 aParam;   // u in [0,1] along, v in [-1,1] across
attribute float aSeed;   // 0..1 per glyph

uniform float uTime;
uniform float uShapeA;
uniform float uShapeB;
uniform float uMix;
uniform float uIntro;
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

// offset from a centerline point across the ribbon, twisted by tw around the tangent
vec3 across(vec3 c0, vec3 c1, float w, float tw) {
  vec3 T = normalize(c1 - c0 + 1e-5);
  vec3 up = abs(T.y) > 0.95 ? vec3(1., 0., 0.) : vec3(0., 1., 0.);
  vec3 B = normalize(cross(T, up));
  vec3 N = cross(B, T);
  return (N * cos(tw) + B * sin(tw)) * w;
}

// Shape 0, the liquidity ring: a wide, flat torus of glyph chips. Glyphs only cover the half of the band that faces
// the camera (pc ± ~100°), so the ring reads as a solid, lit surface with a visible front wall instead of a flat disc.
// Rows: v = -1 traces the outer contour (the top edge behind, the left flank), v = -.905 the inner contour (the near
// edge of the hole); both glow. The two rows at v > .86 are a spray of specks off the outer edge, everything else
// is the body. The orbits, nodes, dust and the smooth edge glow live in ring-orbits.ts.
vec3 gRingColor;   // shading of the last cRing call, read by shapeColor and main
float gRingKind;   // 0 body, 1 contour, 3 spray, 4 sparkle
vec3 cRing(float u, float v, out float fade, out float size) {
  float h1 = hash(aSeed * 5.3), h2 = hash(aSeed * 9.1), h3 = hash(aSeed * 13.7);
  float s = (u + (h3 - .5) / 240.) * TAU + uTime * .03;
  float pc = atan(sin(RING_PITCH), RING_FLAT * sin(s) * cos(RING_PITCH)); // tube angle that faces the camera
  float phi;
  float rr;
  float outer = 1. - step(-.95, v);
  if (v < -.86) {
    gRingKind = 1.;
    phi = pc + (outer > .5 ? -1. : 1.) * (PI * .5 - .1) + (h1 - .5) * .1;
    rr = RING_TUBE * (1. + (h2 - .5) * .05);
  } else if (v > .86) {
    gRingKind = 3.;
    phi = pc - .9 + (h1 - .5) * 2.6;
    rr = RING_TUBE * (1.1 + h2 * h2 * 1.4);
  } else {
    gRingKind = step(.92, hash(aSeed * 31.7)) * 4.;
    phi = pc + (v + (h1 - .5) * .095) / .86 * 1.8;
    rr = RING_TUBE * mix(.8, 1.05, h2);
  }
  float rad = RING_R + rr * cos(phi);
  vec3 p = vec3(cos(s) * rad, rr * RING_FLAT * sin(phi), sin(s) * rad);

  // shading in view space
  mat3 rot = frameRot();
  vec3 n = rot * normalize(vec3(RING_FLAT * cos(phi) * cos(s), sin(phi), RING_FLAT * cos(phi) * sin(s)));
  float facing = dot(n, normalize(cameraPosition - (rot * p * uScale + uOffset)));
  vec2 dir = normalize((rot * vec3(cos(s), 0., sin(s))).xy + 1e-5);
  float glint = ringGlint(dir);
  float key = max(dot(n, normalize(vec3(-.35, .9, .25))), 0.);
  float vis = smoothstep(-.1, .3, facing);
  // light spills from the lit contours into the band: -1 at the outer contour, 1 at the inner one
  float band = (phi - pc) / (PI * .5);
  float spill = ringContourGain(dir, 1.) * pow(clamp(-band, 0., 1.), 3.) + ringContourGain(dir, 0.) * pow(clamp(band, 0., 1.), 3.);
  if (gRingKind == 1.) {
    float gain = ringContourGain(dir, outer);
    gRingColor = mix(uColorA, uColorHot, clamp(.1 + .45 * gain, 0., 1.));
    fade = .1 + .9 * gain;
    size = .6;
  } else if (gRingKind == 3.) {
    gRingColor = h3 > .55 ? uColorC : uColorA;
    fade = .5 - h2 * .3;
    size = .3;
  } else if (gRingKind == 4.) {
    gRingColor = mix(uColorB, uColorHot, h3);
    fade = vis * (.55 + .45 * sin(uTime * (1. + h2 * 3.) + h1 * 40.)) * 1.5;
    size = .5;
  } else {
    // lime on the left, drifting to teal toward the near right; most chips sit dark, a few catch the light
    float teal = smoothstep(.5, 1., h3) * .85 + .45 * smoothstep(-.2, .8, dir.x) * smoothstep(.3, -.6, dir.y);
    float tone = hash(aSeed * 41.3);
    tone *= tone;
    gRingColor = mix(mix(uColorA, uColorB, min(teal, 1.)) * (.45 + .55 * key), uColorHot, .25 * min(spill, 1.) + .2 * tone);
    // the far side's inner wall faces the camera through the hole: keep it dense down to the hole's edge
    float wall = smoothstep(.2, .8, dir.y) * smoothstep(0., .8, band);
    fade = vis * ((.16 + .4 * key) * (.45 + .5 * glint) + .8 * spill + .35 * wall) * (.6 + .9 * tone);
    size = .4 + .75 * h2 * h2;
  }
  // the near side is a little larger and brighter than the far side (the depth squeeze flattens the perspective)
  float near = (rot * p).z / (RING_R + RING_TUBE);
  size *= 1. + .3 * near;
  fade *= .8 + .25 * near;
  return p;
}
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

vec3 ribbon(int k, float u, float v, out float fade, out float size) {
  fade = 1.;
  size = 1.;
  float s = u * TAU;
  float e = .002 * TAU;
  if (k == 0) return cRing(u, v, fade, size);
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
  if (k == 0) return gRingColor;
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
  float sa;
  float sb;
  vec3 pa = ribbon(ka, u, v, fa, sa);
  vec3 pb = ribbon(kb, u, v, fb, sb);

  // staggered morph: every glyph leaves at a slightly different moment, and lifts off the surface mid-flight
  float m = clamp((uMix - aSeed * .3) / .7, 0., 1.);
  m = m * m * (3. - 2. * m);
  vec3 scatter = vec3(hash(aSeed * 7.1) - .5, hash(aSeed * 11.3) - .5, hash(aSeed * 17.7) - .5);
  vec3 p = mix(pa, pb, m) + scatter * sin(m * PI) * 1.3;
  float fade = mix(fa, fb, m);

  // intro: glyphs condense out of a wide cloud
  float intro = smoothstep(0., 1., clamp(uIntro * 1.4 - aSeed * .4, 0., 1.));
  p = mix(scatter * 9., p, intro);

  p = toFrame(p);
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

  float size = uGlyphSize * mix(sa, sb, m) * (1. + hover * 1.5 + ring * 1.3) * (.65 + .35 * hash(aSeed * 3.3));
  // ring chips lie at random angles; the other sets stay upright
  int kn = m < .5 ? ka : kb;
  float spin = kn == 0 ? hash(aSeed * 21.1) * TAU : 0.;
  mv.xy += mat2(cos(spin), sin(spin), -sin(spin), cos(spin)) * position.xy * size;
  gl_Position = projectionMatrix * mv;

  // each section has its own glyph set (atlas row); the set flips per glyph during the morph
  float rate = (.35 + aSeed * 1.5) * (kn == 0 ? .5 : 1.) + hover * 24. + ring * 24.;
  float tick = floor(uTime * rate + aSeed * 100.);
  float row = m < .5 ? float(ka) : float(kb);
  float col = floor(hash(aSeed * 91.7 + tick) * uAtlasGrid.x);
  // ring set: chips 0-13 for the surface, the solid square (11) for sparkles, the dot (14) for the spray
  if (kn == 0) col = gRingKind == 4. ? 11. : gRingKind == 3. ? 14. : floor(hash(aSeed * 91.7 + tick) * 14.);
  vUv = (vec2(col, uAtlasGrid.y - 1. - row) + uv) / uAtlasGrid;

  // the ring shades itself in cRing (fade), so it skips the edge emphasis and most of the depth fade
  float wRing = (ka == 0 ? 1. - m : 0.) + (kb == 0 ? m : 0.);
  float edge = mix(smoothstep(.5, 1., abs(v)), 1., wRing);
  vec3 color = mix(shapeColor(ka, u, v), shapeColor(kb, u, v), m);
  vColor = mix(color, uColorHot, clamp(hover * .85 + ring * .7, 0., 1.));
  float depthFade = smoothstep(10., 3.4, -mv.z);
  depthFade = mix(depthFade, .7 + .3 * depthFade, wRing);
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

/**
 * Glyph set per shape (16 each), one atlas row per section. The ring's set (row 0) is drawn, not typed: outlined chips
 * (0-9), squares (10-11), brackets (12-13), a dot (14) and a ring (15); see `drawRingChips` in glyph-ribbon.tsx.
 */
export const GLYPH_SETS = [
  null,
  "→←↗↘⇢⇄⟶↔⇉⤳>~·:↦⇥",
  "∿≈~%∆δσ±·:+12345",
  "▁▂▃▄▅▆▇█▏▎▍▌|¦:·",
  "↑⇡▲△^$⌃*+·:01ΔΣ∫",
  "⊕⊗∞∾≡=¤$%·:+×◇○∥",
  "░▒▓█*·'.`^×+:;~,",
  "{}<>/=;()[]$#_01",
];
