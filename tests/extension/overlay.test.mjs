import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadContent } from "./helpers.mjs";

function load(html = "<title>Page</title><button>Go</button>") {
  const w = loadContent(html, []);
  const sent = [];
  w.browser = { runtime: { sendMessage: async (m) => void sent.push(m) } };
  w.eval(readFileSync("extension/content/overlay.js", "utf8"));
  return { w, sent };
}
const host = (w) => w.document.getElementById("__sc_overlay");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("notMountedUntilUsed", () => {
  const { w } = load();
  assert.equal(host(w), null);
  w.SC.overlay.status(null);
  assert.equal(host(w), null);
});

test("statusMountsAndUnmounts", () => {
  const { w } = load();
  const orig = w.document.title;
  w.SC.overlay.status("Нажимаю «Найти»");
  assert.ok(host(w));
  assert.equal(w.document.title, "● " + orig);
  w.SC.overlay.status("Другое");
  w.SC.overlay.status("Другое");
  assert.equal(w.document.querySelectorAll("#__sc_overlay").length, 1);
  assert.equal(w.document.title, "● " + orig);
  w.SC.overlay.status(null);
  assert.equal(host(w), null);
  assert.equal(w.document.title, orig);
});

test("titleChangedByPageOnlyPrefixStripped", () => {
  const { w } = load();
  w.SC.overlay.status("x");
  w.document.title = "● New";
  w.SC.overlay.status(null);
  assert.equal(w.document.title, "New");
});

test("hostIgnoresPointer", () => {
  const { w } = load();
  w.SC.overlay.status("x");
  const cs = w.getComputedStyle(host(w));
  assert.equal(cs.pointerEvents, "none");
  assert.equal(cs.position, "fixed");
  assert.equal(cs.zIndex, "2147483647");
  assert.equal(host(w).shadowRoot, null, "closed shadow root");
});

test("stopSendsEvent", () => {
  const { w, sent } = load();
  w.SC.overlay.status("x");
  const b = w.SC.overlay._stopButtonForTest();
  b.click();
  assert.equal(JSON.stringify(sent), '[{"event":"stop"}]');
  assert.ok(b.disabled);
});

test("moveToResolvesAndPulseCleansUp", async () => {
  const { w } = load();
  const t0 = Date.now();
  await w.SC.overlay.moveTo(w.document.querySelector("button"));
  assert.ok(Date.now() - t0 >= 340);
  assert.ok(host(w));
  w.SC.overlay.pulse();
  await sleep(320);
  w.SC.overlay.status(null);
  assert.equal(host(w), null);
});

test("subframeForwardsToTop", async () => {
  const { w } = load("<title>T</title><iframe></iframe>");
  const fw = w.document.querySelector("iframe").contentWindow;
  fw.browser = w.browser;
  fw.eval(readFileSync("extension/content/overlay.js", "utf8"));
  assert.notEqual(fw.top, fw);
  fw.SC.overlay.status("hi");
  assert.equal(fw.document.getElementById("__sc_overlay"), null);
  await sleep(50);
  assert.ok(host(w), "mounted in top frame");
  fw.SC.overlay.status(null);
  await sleep(50);
  assert.equal(host(w), null);
});
