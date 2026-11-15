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

test("stopSendsEventAndConfirms", async () => {
  const { w, sent } = load();
  w.SC.overlay.status("x");
  const b = w.SC.overlay._stopButtonForTest();
  b.click();
  await sleep(10);
  assert.equal(JSON.stringify(sent), '[{"event":"stop"}]');
  assert.ok(b.disabled);
});

test("stopFailureKeepsButtonEnabled", async () => {
  for (const mode of ["reject", "throw"]) {
    const { w } = load();
    w.browser.runtime.sendMessage = mode === "reject" ? () => Promise.reject(new Error("x")) : () => { throw new Error("x"); };
    w.SC.overlay.status("x");
    const b = w.SC.overlay._stopButtonForTest();
    b.click();
    await sleep(10);
    assert.ok(!b.disabled, mode);
    assert.equal(b.parentNode.querySelector(".txt").textContent, "Не удалось остановить", mode);
  }
});

test("statusNullResolvesPendingMoveTo", async () => {
  const { w } = load();
  const p = w.SC.overlay.moveTo(w.document.querySelector("button"));
  w.SC.overlay.status(null);
  const r = await Promise.race([p.then(() => "ok"), sleep(200).then(() => "hang")]);
  assert.equal(r, "ok");
});

test("pageCssCannotOverrideHost", () => {
  const { w } = load("<title>T</title><style>div{display:none!important;pointer-events:auto!important;position:static!important;visibility:hidden!important;opacity:0!important}</style>");
  w.SC.overlay.status("x");
  const cs = w.getComputedStyle(host(w));
  assert.notEqual(cs.display, "none");
  assert.equal(cs.pointerEvents, "none");
  assert.equal(cs.position, "fixed");
  assert.equal(cs.visibility, "visible");
  assert.equal(cs.opacity, "1");
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

test("noMessageListenerAtLoad", () => {
  const w = loadContent("<title>T</title>", []);
  let n = 0;
  const orig = w.addEventListener.bind(w);
  w.addEventListener = (...a) => { n++; return orig(...a); };
  w.browser = { runtime: { sendMessage: async () => {} } };
  w.eval(readFileSync("extension/content/overlay.js", "utf8"));
  assert.equal(n, 0);
});

test("subframeIsNoop", async () => {
  const { w } = load("<title>T</title><iframe></iframe><button>b</button>");
  const fw = w.document.querySelector("iframe").contentWindow;
  fw.browser = w.browser;
  fw.eval(readFileSync("extension/content/overlay.js", "utf8"));
  assert.notEqual(fw.top, fw);
  fw.SC.overlay.status("hi");
  fw.SC.overlay.pulse();
  await fw.SC.overlay.moveTo(fw.document.body);
  await sleep(30);
  assert.equal(host(w), null);
  assert.equal(fw.document.getElementById("__sc_overlay"), null);
});
