import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

function load(file, extra = {}) {
  const ctx = vm.createContext({ console, JSON, Promise, URL, ...extra });
  vm.runInContext(readFileSync(file, "utf8"), ctx);
  return ctx;
}

function fakeBrowser({ tabs = [], windowFocused = true, syncCompleteOnCreate = false, reload = true } = {}) {
  const calls = { create: [], update: [], executeScript: [], capture: [], reload: [] };
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
        if (syncCompleteOnCreate) fire(t.id, "complete");
        else if (o.url) setTimeout(() => fire(t.id, "complete"), 0);
        return t;
      },
      update: async (id, o) => {
        calls.update.push([id, o]);
        Object.assign(byId.get(id), o);
        setTimeout(() => { fire(id, "loading"); fire(id, "complete"); }, 0);
        return byId.get(id);
      },
      ...(reload ? { reload: async (id) => { calls.reload.push(id); setTimeout(() => { fire(id, "loading"); fire(id, "complete"); }, 0); } } : {}),
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

function fakeTimers() {
  const list = [];
  let n = 0;
  return {
    setTimeout: (f, ms) => { list.push({ f, ms, id: ++n }); return n; },
    clearTimeout: (id) => { const i = list.findIndex((t) => t.id === id); if (i >= 0) list.splice(i, 1); },
    pending: (ms) => list.filter((t) => t.ms === ms).length,
    fire: (ms) => { const i = list.findIndex((t) => t.ms === ms); assert.ok(i >= 0, `no timer ${ms}`); const [t] = list.splice(i, 1); t.f(); },
  };
}
const tick = () => new Promise((r) => setImmediate(r));

function setup(opts, sendToTab) {
  const fb = fakeBrowser(opts);
  const timers = fakeTimers();
  const ctx = load("extension/bg/handlers.js", { setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
  const state = { agentTab: null };
  const deps = { browser: fb.browser, sendToTab: sendToTab ?? (async () => ({})), state };
  ctx.SCHandlers.watch(fb.browser, state);
  const H = { handle: async (...a) => JSON.parse(JSON.stringify(await ctx.SCHandlers.handle(...a))) };
  return { H, deps, state, fb, timers };
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

// ---- load waiting ----
const waitingNav = (action, opts = {}, send) => {
  const t = setup({ tabs: [{ id: 5, url: "https://a/", title: "T" }], ...opts }, send ?? (async () => ({})));
  t.state.agentTab = 5;
  return t;
};

for (const action of ["back", "forward", "reload"]) {
  test(`navigate ${action}: resolves after loading+complete`, async () => {
    const sent = [];
    const t = waitingNav(action, { reload: false }, async (id, m) => { sent.push(m); setTimeout(() => { t.fb.fire(5, "loading"); t.fb.fire(5, "complete"); }, 0); return {}; });
    assert.deepEqual(await t.H.handle("navigate", { action }, t.deps), { url: "https://a/", title: "T" });
    assert.equal(sent[0].method, "navigate");
    assert.equal(sent[0].params.action, action);
  });

  test(`navigate ${action}: no loading within 3s resolves with current url`, async () => {
    const t = waitingNav(action, { reload: false });
    const p = t.H.handle("navigate", { action }, t.deps);
    await tick();
    t.timers.fire(3000);
    assert.deepEqual(await p, { url: "https://a/", title: "T" });
  });
}

test("reload uses tabs.reload when available", async () => {
  const t = waitingNav("reload");
  await t.H.handle("navigate", { action: "reload" }, t.deps);
  assert.deepEqual(t.fb.calls.reload, [5]);
});

test("reload via content tolerates a lost reply", async () => {
  const t = waitingNav("reload", { reload: false }, async () => {
    setTimeout(() => { t.fb.fire(5, "loading"); t.fb.fire(5, "complete"); }, 0);
    throw new Error("Message port closed before a response was received");
  });
  assert.deepEqual(await t.H.handle("navigate", { action: "reload" }, t.deps), { url: "https://a/", title: "T" });
  assert.equal(t.fb.calls.executeScript.length, 0);
});

test("late pre-navigation complete does not resolve", async () => {
  const t = waitingNav("x");
  let done = false;
  const p = t.H.handle("navigate", { action: "back" }, t.deps).then((r) => { done = true; return r; });
  await tick();
  t.fb.fire(5, "complete");
  await tick();
  assert.equal(done, false);
  t.fb.fire(5, "loading");
  t.fb.fire(5, "complete");
  await p;
  assert.equal(done, true);
});

test("30s timeout after loading started", async () => {
  const t = waitingNav("x", { reload: false }, async () => ({}));
  const p = t.H.handle("navigate", { action: "back" }, t.deps);
  await tick();
  t.fb.fire(5, "loading");
  t.timers.fire(30000);
  assert.equal(await code(p), "timeout");
});

test("tabs.create with url: complete fired synchronously during create resolves", async () => {
  const t = setup({ syncCompleteOnCreate: true, tabs: [{ id: 1, index: 0, active: true }] });
  const r = await t.H.handle("tabs.create", { url: "https://x/" }, t.deps);
  assert.equal(t.state.agentTab, r.tabId);
});

test("tabs.create with url: timeout keeps agent tab but returns error", async () => {
  const t = setup({ tabs: [{ id: 1, index: 0, active: true }] });
  t.fb.browser.tabs.create = async (o) => { t.state.__c = 1; return { id: 77, windowId: 1, status: "loading" }; };
  t.fb.browser.tabs.get = async () => ({ id: 77, status: "loading" });
  const p = t.H.handle("tabs.create", { url: "https://x/" }, t.deps);
  await tick(); await tick();
  t.timers.fire(30000);
  assert.equal(await code(p), "timeout");
  assert.equal(t.state.agentTab, 77);
});

// ---- content/main.js ----
function loadMain({ top = true, SC = {} } = {}) {
  const listeners = [];
  const win = {};
  win.top = top ? win : {};
  const ctx = vm.createContext({
    window: win, SC, history: { back() { SC.__h = "back"; }, forward() { SC.__h = "forward"; } },
    location: { reload() { SC.__h = "reload"; } },
    browser: { runtime: { onMessage: { addListener: (f) => listeners.push(f) } } },
  });
  vm.runInContext(readFileSync("extension/content/main.js", "utf8"), ctx);
  return { listeners, SC: ctx.SC };
}

test("main: top frame maps methods to SC", async () => {
  const { listeners } = loadMain({ SC: { snapshot: (f) => `snap:${f}`, find: (q) => [{ ref: q }], domType: (r, t) => t + r } });
  assert.equal(listeners.length, 1);
  assert.deepEqual(j(await listeners[0]({ method: "page.snapshot", params: {} })), { text: "snap:interactive" });
  assert.deepEqual(j(await listeners[0]({ method: "page.find", params: { query: "q" } })), { matches: [{ ref: "q" }] });
  assert.deepEqual(j(await listeners[0]({ method: "el.domType", params: { ref: "e1", text: "hi" } })), { value: "hie1" });
  assert.deepEqual(j(await listeners[0]({ method: "navigate", params: { action: "back" } })), {});
  assert.equal(listeners[0]({ method: "unknown" }), undefined);
});

test("main: subframe registers no listener", () => {
  assert.equal(loadMain({ top: false }).listeners.length, 0);
});

test("main: errors map to {error}", async () => {
  const { listeners } = loadMain({ SC: {
    snapshot: () => { throw { code: "not_found", message: "gone" }; },
    find: () => { throw new Error("kaput"); },
  } });
  assert.deepEqual(j(await listeners[0]({ method: "page.snapshot", params: {} })), { error: { code: "not_found", message: "gone" } });
  assert.deepEqual(j(await listeners[0]({ method: "page.find", params: {} })), { error: { code: "internal", message: "kaput" } });
});

// ---- background.js wiring ----
test("background: idle hides overlay, content stop forwards event", async () => {
  const sockets = [];
  class WS { constructor() { this.readyState = 1; this.sent = []; sockets.push(this); } send(s) { this.sent.push(JSON.parse(s)); } }
  const sent = [];
  let onMsg;
  const browser = {
    tabs: { sendMessage: async (id, m, o) => { sent.push([id, m, o]); return {}; }, onRemoved: { addListener() {} } },
    runtime: { onMessage: { addListener: (f) => { onMsg = f; } } },
  };
  const ctx = vm.createContext({ console, JSON, Promise, WebSocket: WS, setTimeout: () => 1, browser });
  for (const f of ["bg/link.js", "bg/handlers.js", "background.js"]) vm.runInContext(readFileSync(`extension/${f}`, "utf8"), ctx);
  const ws = sockets[0];
  // no agent tab yet: idle is a no-op
  ws.onmessage({ data: JSON.stringify({ type: "event", name: "idle", data: {} }) });
  assert.equal(sent.length, 0);
  ctx.SCHandlers.handle; // loaded
  vm.runInContext("state.agentTab = 9", ctx);
  ws.onmessage({ data: JSON.stringify({ type: "event", name: "idle", data: {} }) });
  assert.deepEqual(j(sent[0]), [9, { method: "overlay.status", params: { text: null } }, { frameId: 0 }]);
  onMsg({ event: "stop" });
  assert.deepEqual(j(ws.sent.at(-1)), { type: "event", name: "stop", data: {} });
});

// ---- final-review fixes ----
test("siteCheckRoutesToContent", async () => {
  const sent = [];
  const { H, deps, state } = setup({ tabs: [{ id: 5 }] }, async (id, m) => { sent.push([id, m.method]); return {}; });
  state.agentTab = 5;
  assert.deepEqual(await H.handle("site.check", {}, deps), {});
  assert.deepEqual(sent, [[5, "site.check"]]);
});

test("main: site.check maps to SC.checkSite", async () => {
  const { listeners } = loadMain({ SC: { checkSite: async () => { throw { code: "site_not_allowed", message: "m" }; } } });
  assert.deepEqual(j(await listeners[0]({ method: "site.check", params: {} })), { error: { code: "site_not_allowed", message: "m" } });
});

test("noAgentTabMessageNamesTools", async () => {
  const { H, deps } = setup({});
  await assert.rejects(H.handle("page.snapshot", {}, deps), (e) => /tab_create/.test(e.message) && /tab_select/.test(e.message) && !/tabs_/.test(e.message));
});

test("urlSchemesRestricted", async () => {
  const { H, deps, state, fb } = setup({ tabs: [{ id: 5, index: 0, active: true }] });
  state.agentTab = 5;
  for (const url of ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "about:config", "nonsense"]) {
    assert.equal(await code(H.handle("navigate", { url }, deps)), "bad_request", url);
    assert.equal(await code(H.handle("tabs.create", { url }, deps)), "bad_request", url);
  }
  assert.equal(fb.calls.update.length + fb.calls.create.length, 0);
  await H.handle("navigate", { url: "about:blank" }, deps);
  await H.handle("navigate", { url: "https://b/" }, deps);
  assert.equal(fb.calls.update.length, 2);
});

test("agentTabChangeHidesOverlayOnOldTab", async () => {
  const sent = [];
  const { H, deps, state } = setup({ tabs: [{ id: 5 }, { id: 6 }, { id: 1, index: 0, active: true }] }, async (id, m) => { sent.push([id, j(m)]); return {}; });
  await H.handle("tabs.select", { tabId: 5 }, deps);
  assert.equal(sent.length, 0); // no previous agent tab
  await H.handle("tabs.select", { tabId: 5 }, deps);
  assert.equal(sent.length, 0); // same tab
  await H.handle("tabs.select", { tabId: 6 }, deps);
  assert.deepEqual(sent, [[5, { method: "overlay.status", params: { text: null } }]]);
  const r = await H.handle("tabs.create", {}, deps);
  assert.deepEqual(sent.at(-1), [6, { method: "overlay.status", params: { text: null } }]);
  assert.equal(state.agentTab, r.tabId);
});

test("agentTabChangeToleratesOverlayFailure", async () => {
  const { H, deps, state } = setup({ tabs: [{ id: 5 }, { id: 6 }] }, async () => { throw new Error("gone"); });
  state.agentTab = 5;
  await H.handle("tabs.select", { tabId: 6 }, deps);
  assert.equal(state.agentTab, 6);
});

