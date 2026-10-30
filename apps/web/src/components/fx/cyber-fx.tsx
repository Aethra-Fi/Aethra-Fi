"use client";

import * as React from "react";

const SELECTOR = ".fx-cyber";
const GLYPHS = "!<>-_\\/[]{}=+*^?#01$%&XAETHR";
/** Labels longer than this are left alone (decode reads as noise on long text). */
const MAX_DECODE = 40;

interface Run {
  node: Text;
  text: string;
  /** what we last wrote; anything else means React rewrote the node, so the run lets go of it */
  last: string;
  live: boolean;
}

/** Label decode: the text turns into glyphs and resolves left to right. */
function decode(el: HTMLElement, busy: WeakSet<HTMLElement>) {
  if (busy.has(el)) return;
  const runs: Run[] = [];
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const text = n.nodeValue ?? "";
    if (text.trim()) runs.push({ node: n as Text, text, last: text, live: true });
  }
  const total = runs.reduce((sum, r) => sum + r.text.length, 0);
  if (!total || total > MAX_DECODE) return;
  busy.add(el);
  // the accessible name stays the real label while the visible text is scrambled
  const named = el.hasAttribute("aria-label");
  if (!named) el.setAttribute("aria-label", el.textContent?.trim() ?? "");
  const t0 = performance.now();
  const duration = 240 + total * 16;
  let lastStep = 0;
  const step = (now: number) => {
    const p = Math.min(1, (now - t0) / duration);
    // new glyphs about 22 times a second, the final frame always lands
    if (p < 1 && now - lastStep < 45) {
      requestAnimationFrame(step);
      return;
    }
    lastStep = now;
    const resolved = Math.floor(p * total);
    let offset = 0;
    for (const r of runs) {
      if (r.live && r.node.nodeValue !== r.last) r.live = false;
      if (r.live) {
        let out = "";
        for (let i = 0; i < r.text.length; i++) {
          const ch = r.text[i]!;
          out += offset + i < resolved || ch.trim() === "" ? ch : GLYPHS[(Math.random() * GLYPHS.length) | 0];
        }
        r.node.nodeValue = out;
        r.last = out;
      }
      offset += r.text.length;
    }
    if (p < 1) requestAnimationFrame(step);
    else {
      if (!named) el.removeAttribute("aria-label");
      busy.delete(el);
    }
  };
  requestAnimationFrame(step);
}

/** Spark burst: a diamond pulse and shards flying out from the press point. */
function burst(x: number, y: number) {
  const root = document.createElement("span");
  root.className = "fx-burst";
  root.setAttribute("aria-hidden", "true");
  root.style.left = `${x}px`;
  root.style.top = `${y}px`;
  const shards = 10;
  for (let i = 0; i < shards; i++) {
    const s = document.createElement("i");
    const a = (i / shards) * Math.PI * 2 + Math.random() * 0.5;
    const r = 18 + Math.random() * 26;
    s.style.setProperty("--dx", `${(Math.cos(a) * r).toFixed(1)}px`);
    s.style.setProperty("--dy", `${(Math.sin(a) * r).toFixed(1)}px`);
    root.appendChild(s);
  }
  document.body.appendChild(root);
  window.setTimeout(() => root.remove(), 600);
}

/** Replays the press glitch (globals.css `.fx-cyber[data-fx-hit]`). */
function hit(el: HTMLElement) {
  el.removeAttribute("data-fx-hit");
  void el.offsetWidth;
  el.setAttribute("data-fx-hit", "");
}

const target = (e: Event) => (e.target instanceof Element ? e.target.closest<HTMLElement>(SELECTOR) : null);

/**
 * Document-level listeners for every `.fx-cyber` element (landing buttons, header), so call sites only add the
 * class. Hover and press styles live in globals.css; this adds what CSS can't: the label decode on hover, the press
 * glitch replay and the spark burst. Reduced motion turns all of it off.
 */
export function CyberFx() {
  React.useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    const busy = new WeakSet<HTMLElement>();

    const onOver = (e: PointerEvent) => {
      if (reduced.matches || e.pointerType !== "mouse") return;
      const el = target(e);
      if (!el || (e.relatedTarget instanceof Node && el.contains(e.relatedTarget))) return;
      decode(el, busy);
    };
    const onOut = (e: PointerEvent) => {
      const el = target(e);
      if (!el || (e.relatedTarget instanceof Node && el.contains(e.relatedTarget))) return;
      el.removeAttribute("data-fx-hit");
    };
    const onDown = (e: PointerEvent) => {
      if (reduced.matches || e.button !== 0) return;
      const el = target(e);
      if (!el) return;
      hit(el);
      burst(e.clientX, e.clientY);
    };
    // keyboard activation (Enter / Space) has no pointer: burst from the element's center
    const onClick = (e: MouseEvent) => {
      if (reduced.matches || e.detail !== 0) return;
      const el = target(e);
      if (!el) return;
      const r = el.getBoundingClientRect();
      hit(el);
      burst(r.left + r.width / 2, r.top + r.height / 2);
    };

    document.addEventListener("pointerover", onOver, { passive: true });
    document.addEventListener("pointerout", onOut, { passive: true });
    document.addEventListener("pointerdown", onDown, { passive: true });
    document.addEventListener("click", onClick, { passive: true });
    return () => {
      document.removeEventListener("pointerover", onOver);
      document.removeEventListener("pointerout", onOut);
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("click", onClick);
    };
  }, []);
  return null;
}
