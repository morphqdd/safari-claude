import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadContent } from "./helpers.mjs";

const FILES = ["extension/content/snapshot.js", "extension/content/risk.js", "extension/content/sites.js", "extension/content/actions.js"];

async function load(html, { allow = true } = {}) {
  const w = loadContent(html, []);
  const store = {};
  w.browser = {
    storage: { local: { get: async (k) => (k in store ? { [k]: store[k] } : {}), set: async (o) => void Object.assign(store, o) } },
  };
  for (const f of FILES) w.eval(readFileSync(f, "utf8"));
  w.Element.prototype.scrollIntoView = function () {};
  if (allow) await w.SC.sites.allow("example.com");
  return w;
}

test("prepareStaleRefReturnsNotFound", async () => {
  const w = await load("<button>Go</button>");
  w.SC.snapshot("interactive");
  w.document.querySelector("button").remove();
  await assert.rejects(w.SC.prepare("e1", "click"), (e) => e.code === "not_found" && /e1/.test(e.message));
});

test("prepareMarksAndReports", async () => {
  const w = await load("<button>Оплатить</button>");
  w.SC.snapshot("interactive");
  const r = await w.SC.prepare("e1", "click");
  assert.equal(r.marker, "__sc_m_e1");
  assert.equal(r.risk.kind, "payment");
  assert.ok(w.document.querySelector("button").classList.contains("__sc_m_e1"));
  w.SC.release("e1");
  assert.ok(!w.document.querySelector("button").classList.contains("__sc_m_e1"));
});

test("prepareSiteGate", async () => {
  const w = await load("<button>Go</button>", { allow: false });
  w.SC.snapshot("interactive");
  await assert.rejects(w.SC.prepare("e1", "click"), (e) => e.code === "site_not_allowed" && e.message === "Разрешите сайт: confirm_action kind=site domain=example.com");
});

test("domClickFiresSequence", async () => {
  const w = await load("<button>Go</button>");
  w.SC.snapshot("interactive");
  const b = w.document.querySelector("button");
  const seen = [];
  for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) b.addEventListener(t, () => seen.push(t));
  w.SC.domClick("e1");
  assert.deepEqual(seen, ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]);
});

test("domTypeReactControlled", async () => {
  const w = await load(`<input aria-label="x">`);
  w.SC.snapshot("interactive");
  const i = w.document.querySelector("input");
  let inputs = 0;
  Object.defineProperty(i, "value", { configurable: true, get() { return this._v ?? ""; }, set(v) { this._v = "SHADOW" + v; } });
  i.addEventListener("input", () => inputs++);
  const out = w.SC.domType("e1", "abc");
  assert.equal(inputs, 1);
  assert.equal(Object.getOwnPropertyDescriptor(w.HTMLInputElement.prototype, "value").get.call(i), "abc");
  assert.equal(out, "abc");
});

test("domTypeSelect", async () => {
  const w = await load(`<select aria-label="s"><option value="a">Alpha</option><option value="b">Beta</option></select>`);
  w.SC.snapshot("interactive");
  assert.equal(w.SC.domType("e1", "Beta"), "b");
});

test("domTypeContentEditableFallback", async () => {
  const w = await load(`<div contenteditable="true"></div>`);
  w.SC.snapshot("interactive");
  assert.equal(w.SC.domType("e1", "hi"), "hi");
});

test("domKeyEnterSubmitsForm", async () => {
  const w = await load(`<form><input id="a" aria-label="q"></form>`);
  const f = w.document.querySelector("form");
  let n = 0;
  f.requestSubmit = () => { n++; };
  w.document.getElementById("a").focus();
  const keys = [];
  w.document.addEventListener("keydown", (e) => keys.push(e.key + (e.metaKey ? "+meta" : "")));
  w.SC.domKey("Enter");
  w.SC.domKey("cmd+a");
  assert.equal(n, 1);
  assert.deepEqual(keys, ["Enter", "a+meta"]);
  assert.throws(() => w.SC.domKey("Bogus"), (e) => e.code === "bad_request");
});

test("scrollAndValue", async () => {
  const w = await load(`<input aria-label="q" value="v">`);
  w.SC.snapshot("interactive");
  assert.equal(w.SC.value("e1"), "v");
  let by;
  w.scrollBy = (o) => (by = o);
  w.SC.scroll({});
  assert.equal(by.top, 600);
  w.SC.scroll({ direction: "up", amount: 100 });
  assert.equal(by.top, -100);
});

test("domKeyEnterTextareaDoesNotSubmit", async () => {
  const w = await load(`<form><textarea id="a"></textarea></form>`);
  let n = 0;
  w.document.querySelector("form").requestSubmit = () => { n++; };
  w.document.getElementById("a").focus();
  w.SC.domKey("Enter");
  assert.equal(n, 0);
});

test("domKeyEnterPreventedDoesNotSubmit", async () => {
  const w = await load(`<form><input id="a"></form>`);
  let n = 0;
  w.document.querySelector("form").requestSubmit = () => { n++; };
  const a = w.document.getElementById("a");
  a.focus();
  a.addEventListener("keydown", (e) => e.preventDefault());
  w.SC.domKey("Enter");
  assert.equal(n, 0);
});

test("releaseAfterNewSnapshotRemovesMarker", async () => {
  const w = await load("<button>A</button>");
  w.SC.snapshot("interactive");
  await w.SC.prepare("e1", "click");
  w.document.body.insertAdjacentHTML("afterbegin", "<a href='/x'>L</a>");
  w.SC.snapshot("interactive"); // e1 now another element
  w.SC.release("e1");
  assert.equal(w.document.querySelectorAll(".__sc_m_e1").length, 0);
});

test("prepareFailureLeavesNoMarker", async () => {
  const w = await load("<button>A</button>");
  w.SC.snapshot("interactive");
  await w.SC.prepare("e1", "click");
  w.SC.overlay = { moveTo: async () => { throw new Error("boom"); } };
  await assert.rejects(w.SC.prepare("e1", "click"));
  assert.equal(w.document.querySelectorAll(".__sc_m_e1").length, 0);
});

test("repeatedPrepareLeavesOneMarker", async () => {
  const w = await load("<button>A</button><a href='/x'>L</a>");
  w.SC.snapshot("interactive");
  await w.SC.prepare("e1", "click");
  w.document.body.insertAdjacentHTML("afterbegin", "<i></i>");
  w.document.body.removeChild(w.document.querySelector("i"));
  w.document.querySelector("button").remove();
  w.SC.snapshot("interactive"); // e1 is now the link
  await w.SC.prepare("e1", "click");
  assert.equal(w.document.querySelectorAll(".__sc_m_e1").length, 1);
});
