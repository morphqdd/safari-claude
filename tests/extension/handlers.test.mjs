import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

function load(file, extra = {}) {
  const ctx = vm.createContext({ console, JSON, Promise, ...extra });
  vm.runInContext(readFileSync(file, "utf8"), ctx);
  return ctx;
}

function fakeBrowser({ tabs = [], windowFocused = true } = {}) {
  const calls = { create: [], update: [], executeScript: [], capture: [] };
  const listeners = { updated: [], removed: [] };
  const byId = new Map(tabs.map((t) => [t.id, { status: "complete", windowId: 1, ...t }]));
  let nextId = 100;
  const browser = {
    tabs: {
      query: async (q) => {
        let all = [...byId.values()];
        if (q?.active) all = all.filter((t) => t.active);
        return all;
      },
      get: async (id) => {
        if (!byId.has(id)) throw new Error("No tab");
        return byId.get(id);
      },
      create: async (o) => {
        calls.create.push(o);
        const t = { id: nextId++, windowId: o.windowId ?? 1, active: false, status: "loading", url: o.url ?? "about:blank", title: "" };
        byId.set(t.id, t);
        if (o.url) setTimeout(() => fire(t.id, "complete"), 0);
        return t;
      },
      update: async (id, o) => {
        calls.update.push([id, o]);
        Object.assign(byId.get(id), o);
        setTimeout(() => fire(id, "complete"), 0);
        return byId.get(id);
      },
      executeScript: async (id, o) => { calls.executeScript.push([id, o]); },
      captureVisibleTab: async (w, o) => { calls.capture.push([w, o]); return "data:image/png;base64,AAA"; },
      onUpdated: { addListener: (f) => listeners.updated.push(f), removeListener: (f) => { listeners.updated = listeners.updated.filter((x) => x !== f); } },
      onRemoved: { addListener: (f) => listeners.removed.push(f) },
    },
    windows: { get: async (id) => ({ id, focused: windowFocused }), getLastFocused: async () => ({ id: 1 }) },
  };
  function fire(id, status) {
    byId.get(id).status = status;
    for (const f of [...listeners.updated]) f(id, { status }, byId.get(id));
  }
  return { browser, calls, listeners, fire };
}

function setup(opts, sendToTab) {
  const fb = fakeBrowser(opts);
  const ctx = load("extension/bg/handlers.js", { setTimeout, clearTimeout });
  const state = { agentTab: null };
  const deps = { browser: fb.browser, sendToTab: sendToTab ?? (async () => ({})), state };
  ctx.SCHandlers.watch(fb.browser, state);
  const H = { handle: async (...a) => JSON.parse(JSON.stringify(await ctx.SCHandlers.handle(...a))) };
  return { H, deps, state, fb };
}
const j = (x) => JSON.parse(JSON.stringify(x));
const code = async (p) => { try { await p; } catch (e) { return e.code; } return null; };

test("createIsBackgroundNextToActive", async () => {
  const { H, deps, state, fb } = setup({ tabs: [{ id: 1, index: 3, active: true, windowId: 7, url: "https://a/", title: "A" }] });
  const r = await H.handle("tabs.create", {}, deps);
  assert.deepEqual(j(fb.calls.create[0]), { active: false, index: 4, windowId: 7 });
  assert.equal(state.agentTab, r.tabId);
});

test("noAgentTabError", async () => {
  const { H, deps } = setup({});
  assert.equal(await code(H.handle("page.snapshot", {}, deps)), "no_agent_tab");
});

test("screenshotBackgroundTab", async () => {
  const { H, deps, state, fb } = setup({ tabs: [{ id: 5, index: 0, active: false }] });
  state.agentTab = 5;
  assert.equal(await code(H.handle("tab.screenshot", {}, deps)), "background_tab");
  assert.equal(fb.calls.capture.length, 0);
});

test("screenshotActiveTab", async () => {
  const { H, deps, state, fb } = setup({ tabs: [{ id: 5, index: 0, active: true, windowId: 2 }] });
  state.agentTab = 5;
  assert.deepEqual(await H.handle("tab.screenshot", {}, deps), { dataUrl: "data:image/png;base64,AAA" });
  assert.deepEqual(j(fb.calls.capture[0]), [2, { format: "png" }]);
});

test("reinjectsOnNoReceiver", async () => {
  let n = 0;
  const { H, deps, state, fb } = setup({ tabs: [{ id: 5, index: 0, active: true }] }, async () => {
    if (n++ === 0) throw new Error("Could not establish connection. Receiving end does not exist.");
    return { text: "ok" };
  });
  state.agentTab = 5;
  assert.deepEqual(await H.handle("page.snapshot", {}, deps), { text: "ok" });
  assert.deepEqual(fb.calls.executeScript.map((c) => c[1].file), [
    "content/snapshot.js", "content/risk.js", "content/sites.js", "content/overlay.js", "content/actions.js", "content/main.js",
  ]);
  assert.ok(fb.calls.executeScript.every((c) => c[0] === 5 && c[1].allFrames === true));
});

test("contentErrorPassesThrough", async () => {
  const { H, deps, state } = setup({ tabs: [{ id: 5 }] }, async () => ({ error: { code: "not_found", message: "gone" } }));
  state.agentTab = 5;
  assert.equal(await code(H.handle("el.domClick", { ref: "e1" }, deps)), "not_found");
});

test("agentTabClearedOnRemove", async () => {
  const { H, deps, state, fb } = setup({ tabs: [{ id: 5 }] });
  state.agentTab = 5;
  fb.listeners.removed.forEach((f) => f(5));
  assert.equal(state.agentTab, null);
  assert.equal(await code(H.handle("page.snapshot", {}, deps)), "no_agent_tab");
});

test("navigateWaitsForComplete", async () => {
  const { H, deps, state, fb } = setup({ tabs: [{ id: 5, url: "https://a/", title: "T" }] });
  state.agentTab = 5;
  const r = await H.handle("navigate", { url: "https://b/" }, deps);
  assert.deepEqual(j(fb.calls.update[0]), [5, { url: "https://b/" }]);
  assert.deepEqual(r, { url: "https://b/", title: "T" });
});

test("tabsSelectNotFoundAndOk", async () => {
  const { H, deps, state } = setup({ tabs: [{ id: 5 }] });
  assert.equal(await code(H.handle("tabs.select", { tabId: 9 }, deps)), "not_found");
  await H.handle("tabs.select", { tabId: 5 }, deps);
  assert.equal(state.agentTab, 5);
});

test("tabStateAndList", async () => {
  const { H, deps, state } = setup({ windowFocused: false, tabs: [{ id: 5, windowId: 1, active: true, url: "u", title: "t" }] });
  state.agentTab = 5;
  assert.deepEqual(await H.handle("tab.state", {}, deps), { tabId: 5, url: "u", title: "t", activeInWindow: true, windowFocused: false });
  const l = await H.handle("tabs.list", {}, deps);
  assert.deepEqual(l.tabs, [{ tabId: 5, windowId: 1, url: "u", title: "t", active: true, isAgent: true }]);
});

test("unknownMethod", async () => {
  const { H, deps } = setup({});
  assert.equal(await code(H.handle("bogus", {}, deps)), "bad_request");
});

test("reconnectBackoff", () => {
  const sockets = [];
  class WS { constructor(u) { this.url = u; this.sent = []; sockets.push(this); } send(s) { this.sent.push(JSON.parse(s)); } }
  const timers = [];
  const ctx = load("extension/bg/link.js", { WebSocket: WS, setTimeout: (f, ms) => { timers.push({ f, ms }); return 1; } });
  ctx.SCLink.connect();
  const closeAndRetry = () => { sockets.at(-1).onclose({}); const t = timers.at(-1); t.f(); return t.ms; };
  assert.equal(sockets[0].url, "ws://127.0.0.1:47821");
  sockets[0].onopen();
  assert.deepEqual(sockets[0].sent[0], { type: "hello", role: "extension" });
  const ms = [];
  for (let i = 0; i < 6; i++) ms.push(closeAndRetry());
  assert.deepEqual(ms, [1000, 2000, 5000, 15000, 30000, 30000]);
  sockets.at(-1).onmessage({ data: JSON.stringify({ type: "welcome" }) });
  assert.equal(closeAndRetry(), 1000);
});

test("linkDispatchesRequestsAndEvents", async () => {
  const sockets = [];
  class WS { constructor() { this.readyState = 1; this.sent = []; sockets.push(this); } send(s) { this.sent.push(JSON.parse(s)); } }
  const ctx = load("extension/bg/link.js", { WebSocket: WS, setTimeout: () => 1 });
  const L = ctx.SCLink;
  const events = [];
  L.onRequest = async (m, p) => { if (m === "boom") throw new Error("x"); if (m === "bad") throw { code: "not_found", message: "n" }; return { m, p }; };
  L.onEvent = (n, d) => events.push([n, d]);
  L.connect();
  const ws = sockets[0];
  const msg = async (o) => { ws.onmessage({ data: JSON.stringify(o) }); await new Promise((r) => setImmediate(r)); };
  await msg({ type: "req", id: 1, method: "a", params: { z: 1 } });
  await msg({ type: "req", id: 2, method: "bad", params: {} });
  await msg({ type: "req", id: 3, method: "boom", params: {} });
  await msg({ type: "event", name: "idle", data: {} });
  L.sendEvent("stop", {});
  assert.deepEqual(ws.sent[0], { type: "res", id: 1, result: { m: "a", p: { z: 1 } } });
  assert.deepEqual(ws.sent[1], { type: "res", id: 2, error: { code: "not_found", message: "n" } });
  assert.equal(ws.sent[2].error.code, "internal");
  assert.deepEqual(events, [["idle", {}]]);
  assert.deepEqual(ws.sent[3], { type: "event", name: "stop", data: {} });
});
