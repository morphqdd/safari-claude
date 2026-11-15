import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import vm from "node:vm";
import { loadContent } from "./helpers.mjs";

const j = (x) => JSON.parse(JSON.stringify(x));
const tick = () => new Promise((r) => setImmediate(r));
const ticks = async (n = 5) => { for (let i = 0; i < n; i++) await tick(); };
const BASE = "safari-web-extension://ABCD-1234/";

function fakeStorage() {
  const store = {};
  return {
    store,
    local: {
      get: async (k) => (k in store ? { [k]: j(store[k]) } : {}),
      set: async (o) => void Object.assign(store, j(o)),
    },
  };
}

function setup({ lastFocused = { id: 1, left: 100, top: 50, width: 1000, height: 800 }, tabs = {}, toTab, storage } = {}) {
  const L = {};
  const calls = { create: [], update: [], menus: [], toTab: [] };
  const on = (k) => ({ addListener: (f) => { L[k] = f; } });
  let nextWin = 500;
  const browser = {
    runtime: { getURL: (p) => BASE + p, onMessage: on("message"), onConnect: on("connect") },
    browserAction: { onClicked: on("toolbar") },
    commands: { onCommand: on("command") },
    contextMenus: {
      create: (o, cb) => { if (calls.menus.some((m) => m.id === o.id)) throw new Error("duplicate id"); calls.menus.push(o); cb?.(); },
      removeAll: async () => { calls.menus.length = 0; calls.removeAll = (calls.removeAll ?? 0) + 1; },
      onClicked: on("menu"),
    },
    windows: {
      getLastFocused: async () => lastFocused,
      create: async (o) => { calls.create.push(j(o)); return { id: nextWin++ }; },
      update: async (id, o) => { calls.update.push(j([id, o])); return { id }; },
      onRemoved: on("winRemoved"),
    },
    tabs: {
      get: async (id) => { if (!tabs[id]) throw new Error("No tab"); return tabs[id]; },
      sendMessage: async (id, m, o) => { calls.toTab.push(j(o ? [id, m, o] : [id, m])); return toTab ? toTab(id, m) : {}; },
      onRemoved: on("tabRemoved"),
      executeScript: async () => {},
    },
    storage: storage ?? fakeStorage(),
  };
  const events = [];
  const SCLink = { connect() {}, sendEvent: (n, d) => { events.push(j([n, d])); return true; } };
  const ctx = vm.createContext({ console, JSON, Promise, URL, setTimeout, clearTimeout, browser, SCLink });
  for (const f of ["bg/handlers.js", "bg/chat.js", "background.js"]) {
    vm.runInContext(readFileSync(`extension/${f}`, "utf8"), ctx);
  }
  return { ctx, L, calls, events, SCLink, browser };
}

function port(url, name = "chat") {
  const p = {
    name, sender: { url, tab: { id: 3 } }, posted: [], disconnected: false, msg: null, gone: null,
    postMessage(m) { p.posted.push(j(m)); },
    disconnect() { p.disconnected = true; },
    onMessage: { addListener(f) { p.msg = f; } },
    onDisconnect: { addListener(f) { p.gone = f; } },
  };
  return p;
}
const chatPort = () => port(BASE.toLowerCase() + "chat/chat.html");

const CHAT_WINDOW = { url: BASE + "chat/chat.html", type: "popup", width: 400, height: 800, left: 1100, top: 50 };

test("toolbarOpensChat", async () => {
  const t = setup();
  t.L.toolbar({ id: 1 });
  await ticks();
  assert.deepEqual(t.calls.create, [CHAT_WINDOW]);
  assert.equal(vm.runInContext("state.chatWindow", t.ctx), 500);
  // The toolbar no longer sends Stop.
  assert.deepEqual(t.events, []);
});

test("commandOpensChat", async () => {
  const t = setup();
  t.L.command("other", { id: 1 });
  await ticks();
  assert.equal(t.calls.create.length, 0);
  t.L.command("open-chat", { id: 1 });
  await ticks();
  assert.deepEqual(t.calls.create, [CHAT_WINDOW]);
});

test("secondOpenFocusesExistingWindow", async () => {
  const t = setup();
  // Clicks while the window is being created share that creation.
  t.L.toolbar({ id: 1 });
  t.L.toolbar({ id: 1 });
  await ticks();
  assert.equal(t.calls.create.length, 1);
  assert.deepEqual(t.calls.update, []);
  t.L.command("open-chat", { id: 1 });
  await ticks();
  assert.equal(t.calls.create.length, 1);
  assert.deepEqual(t.calls.update, [[500, { focused: true }]]);
  // Closing the window clears it; the next open creates a new one.
  t.L.winRemoved(42);
  assert.equal(vm.runInContext("state.chatWindow", t.ctx), 500);
  t.L.winRemoved(500);
  assert.equal(vm.runInContext("state.chatWindow", t.ctx), null);
  t.L.toolbar({ id: 1 });
  await ticks();
  assert.equal(t.calls.create.length, 2);
});

test("askPageSendsEventAndOpens", async () => {
  const t = setup();
  await ticks();
  assert.equal(t.calls.removeAll, 1);
  assert.deepEqual(j(t.calls.menus), [{ id: "ask-page", title: "Ask Claude about this page", contexts: ["page"] }]);
  t.L.menu({ menuItemId: "ask-page" }, { id: 12 });
  await ticks();
  assert.deepEqual(t.events, [["chat.askPage", { tabId: 12 }]]);
  assert.equal(t.calls.create.length, 1);
});

test("portFromContentScriptIsDisconnected", async () => {
  const t = setup();
  const bad = port("https://evil.example/chat/chat.html");
  t.L.connect(bad);
  assert.equal(bad.disconnected, true);
  const other = port(BASE + "chat/chat.html", "other");
  t.L.connect(other);
  assert.equal(other.disconnected, true);
  const sneaky = port(BASE + "chatx/chat.html");
  t.L.connect(sneaky);
  assert.equal(sneaky.disconnected, true);
  // Uppercase UUID (as Safari reports) and the tab set are fine.
  const good = port(BASE + "chat/chat.html");
  t.L.connect(good);
  assert.equal(good.disconnected, false);
  const lower = chatPort();
  t.L.connect(lower);
  assert.equal(lower.disconnected, false);
});

test("portMessagesBecomeDaemonEvents", async () => {
  const t = setup();
  const p = chatPort();
  t.L.connect(p);
  p.msg({ type: "send", text: "hi" });
  p.msg({ type: "new" });
  p.msg({ type: "stop" });
  p.msg({ type: "bogus" });
  assert.deepEqual(t.events, [["chat.send", { text: "hi" }], ["chat.new", {}], ["stop", {}]]);
});

test("sendWithoutDaemonReportsError", async () => {
  const t = setup();
  t.SCLink.sendEvent = () => false;
  const p = chatPort();
  t.L.connect(p);
  p.msg({ type: "send", text: "hi" });
  assert.equal(p.posted.length, 1);
  assert.equal(p.posted[0].type, "error");
  assert.ok(p.posted[0].text.length > 0);
});

test("daemonChatEventsReachPorts", async () => {
  const t = setup();
  const a = chatPort(), b = chatPort();
  t.L.connect(a);
  t.L.connect(b);
  t.SCLink.onEvent("chat.delta", { text: "Hel" });
  t.SCLink.onEvent("chat.action", { tool: "mcp__safari__click", input: { ref: "e1" } });
  t.SCLink.onEvent("chat.busy", {});
  for (const p of [a, b]) {
    assert.deepEqual(p.posted, [
      { type: "delta", text: "Hel" },
      { type: "action", tool: "mcp__safari__click", input: { ref: "e1" } },
      { type: "busy" },
    ]);
  }
  // A closed port gets nothing more.
  a.gone();
  t.SCLink.onEvent("chat.notice", { text: "n" });
  assert.equal(a.posted.length, 3);
  assert.deepEqual(b.posted.at(-1), { type: "notice", text: "n" });
  // Non-chat events still work: idle without an agent tab is a no-op.
  t.SCLink.onEvent("idle", {});
  assert.equal(t.calls.toTab.length, 0);
});

test("confirmCardUsesPageDerivedText", async () => {
  const t = setup({
    tabs: { 7: { id: 7, url: "https://Shop.Example.com/cart" } },
    toTab: (_id, m) => (m.method === "el.describe" ? { role: "button", name: "Pay" } : {}),
  });
  vm.runInContext("state.agentTab = 7", t.ctx);
  const p = chatPort();
  t.L.connect(p);
  const res = t.SCLink.onRequest("chat.confirm", { kind: "click", ref: "e5" });
  await ticks();
  assert.deepEqual(t.calls.toTab, [[7, { method: "el.describe", params: { ref: "e5" } }, { frameId: 0 }]]);
  assert.equal(p.posted.length, 1);
  const card = p.posted[0];
  assert.deepEqual(card, { type: "confirm", id: card.id, kind: "click", host: "shop.example.com", element: { role: "button", name: "Pay" } });
  assert.equal(t.calls.create.length, 0); // a port is open: no new window
  p.msg({ type: "confirmReply", id: card.id, decision: "allow" });
  assert.deepEqual(j(await res), { decision: "allow" });

  // type card carries the text to be typed; key card the combo.
  const r2 = t.SCLink.onRequest("chat.confirm", { kind: "type", ref: "e5", text: "hello" });
  await ticks();
  const c2 = p.posted.at(-1);
  assert.deepEqual(c2, { type: "confirm", id: c2.id, kind: "type", host: "shop.example.com", element: { role: "button", name: "Pay" }, text: "hello" });
  assert.notEqual(c2.id, card.id);
  // A reply outside the kind's answers is a refusal.
  p.msg({ type: "confirmReply", id: c2.id, decision: "always" });
  assert.deepEqual(j(await r2), { decision: "deny" });

  const r3 = t.SCLink.onRequest("chat.confirm", { kind: "key", combo: "cmd+enter" });
  await ticks();
  const c3 = p.posted.at(-1);
  assert.deepEqual(c3, { type: "confirm", id: c3.id, kind: "key", host: "shop.example.com", combo: "cmd+enter" });
  p.msg({ type: "confirmReply", id: c3.id, decision: "deny" });
  assert.deepEqual(j(await r3), { decision: "deny" });
});

test("siteCardForAnotherHostIsRefused", async () => {
  const t = setup({ tabs: { 7: { id: 7, url: "https://shop.example.com/" } } });
  vm.runInContext("state.agentTab = 7", t.ctx);
  const p = chatPort();
  t.L.connect(p);
  assert.deepEqual(j(await t.SCLink.onRequest("chat.confirm", { kind: "site", domain: "bank.example" })), { decision: "no" });
  assert.equal(p.posted.length, 0);
  const r = t.SCLink.onRequest("chat.confirm", { kind: "site", domain: "Shop.Example.com" });
  await ticks();
  const c = p.posted.at(-1);
  assert.deepEqual(c, { type: "confirm", id: c.id, kind: "site", host: "shop.example.com" });
  p.msg({ type: "confirmReply", id: c.id, decision: "once" });
  assert.deepEqual(j(await r), { decision: "once" });
});

test("confirmDeniedWhenPortCloses", async () => {
  const t = setup({ tabs: { 7: { id: 7, url: "https://a.example/" } } });
  vm.runInContext("state.agentTab = 7", t.ctx);
  // No chat open: the card opens it and is shown once the page connects.
  const r1 = t.SCLink.onRequest("chat.confirm", { kind: "key", combo: "enter" });
  const r2 = t.SCLink.onRequest("chat.confirm", { kind: "site", domain: "a.example" });
  await ticks();
  assert.equal(t.calls.create.length, 1);
  const p = chatPort();
  t.L.connect(p);
  assert.deepEqual(p.posted.map((m) => m.kind), ["key", "site"]);
  p.gone();
  assert.deepEqual(j(await r1), { decision: "deny" });
  assert.deepEqual(j(await r2), { decision: "no" });
});

test("confirmDeniedWhenWindowClosesBeforeConnect", async () => {
  const t = setup({ tabs: { 7: { id: 7, url: "https://a.example/" } } });
  vm.runInContext("state.agentTab = 7", t.ctx);
  const r = t.SCLink.onRequest("chat.confirm", { kind: "key", combo: "enter" });
  await ticks();
  t.L.winRemoved(500);
  assert.deepEqual(j(await r), { decision: "deny" });
});

test("turnEndAndStopRefusePendingCards", async () => {
  const t = setup({ tabs: { 7: { id: 7, url: "https://a.example/" } } });
  vm.runInContext("state.agentTab = 7", t.ctx);
  const p = chatPort();
  t.L.connect(p);
  const r1 = t.SCLink.onRequest("chat.confirm", { kind: "site", domain: "a.example" });
  await ticks();
  const id1 = p.posted.at(-1).id;
  t.SCLink.onEvent("chat.turnEnd", {});
  assert.deepEqual(j(await r1), { decision: "no" });
  assert.deepEqual(p.posted.slice(-2), [{ type: "cardClosed", id: id1 }, { type: "turnEnd" }]);

  const r2 = t.SCLink.onRequest("chat.confirm", { kind: "key", combo: "enter" });
  await ticks();
  const id2 = p.posted.at(-1).id;
  p.msg({ type: "stop" });
  assert.deepEqual(j(await r2), { decision: "deny" });
  assert.deepEqual(p.posted.at(-1), { type: "cardClosed", id: id2 });
  assert.deepEqual(t.events.at(-1), ["stop", {}]);
  // A late reply to a closed card is ignored.
  p.msg({ type: "confirmReply", id: id2, decision: "allow" });
});

test("linkLossMidTurnEndsWaitAndRefusesCards", async () => {
  const t = setup({ tabs: { 7: { id: 7, url: "https://a.example/" } } });
  vm.runInContext("state.agentTab = 7", t.ctx);
  const p = chatPort();
  t.L.connect(p);
  p.msg({ type: "send", text: "hi" });
  const r = t.SCLink.onRequest("chat.confirm", { kind: "key", combo: "enter" });
  await ticks();
  const id = p.posted.at(-1).id;
  t.SCLink.onClose();
  assert.deepEqual(j(await r), { decision: "deny" });
  assert.equal(p.posted.at(-2).type, "cardClosed");
  assert.equal(p.posted.at(-2).id, id);
  assert.equal(p.posted.at(-1).type, "error");
  assert.ok(p.posted.at(-1).text.length > 0);
  // Reconnect attempts that fail again do not repeat the error.
  const n = p.posted.length;
  t.SCLink.onClose();
  assert.equal(p.posted.length, n);
});

test("linkLossWithoutTurnIsSilent", async () => {
  const t = setup();
  const p = chatPort();
  t.L.connect(p);
  p.msg({ type: "send", text: "hi" });
  t.SCLink.onEvent("chat.turnEnd", {});
  const n = p.posted.length;
  t.SCLink.onClose();
  assert.equal(p.posted.length, n);
  // A refused send (busy) starts no turn either.
  p.msg({ type: "send", text: "again" });
  t.SCLink.onEvent("chat.busy", {});
  t.SCLink.onClose();
  assert.equal(p.posted.length, n + 1);
});

test("backgroundStartClearsSitesOnce", async () => {
  const storage = fakeStorage();
  storage.store["sc.sitesOnce"] = ["left.example"];
  setup({ storage });
  await ticks();
  assert.deepEqual(storage.store["sc.sitesOnce"], []);
});

test("turnEndClearsSitesOnce", async () => {
  const storage = fakeStorage();
  const t = setup({ storage });
  await ticks();
  const deps = { browser: t.browser, state: {}, sendToTab: async () => ({}) };
  await t.ctx.SCHandlers.handle("site.allowOnce", { domain: "a.example" }, deps);
  assert.deepEqual(storage.store["sc.sitesOnce"], ["a.example"]);
  t.SCLink.onEvent("chat.delta", { text: "x" });
  await ticks();
  assert.deepEqual(storage.store["sc.sitesOnce"], ["a.example"]);
  t.SCLink.onEvent("chat.turnEnd", {});
  await ticks();
  assert.deepEqual(storage.store["sc.sitesOnce"], []);
});

test("siteOnceAllowedUntilCleared", async () => {
  const storage = fakeStorage();
  const t = setup({ storage });
  const w = loadContent("<p>x</p>", []);
  w.browser = { storage };
  w.eval(readFileSync("extension/content/sites.js", "utf8"));
  assert.equal(await w.SC.sites.isAllowed("shop.example"), "ask");
  assert.equal(await w.SC.sites.isAllowed("mybank.example"), "denied");
  const deps = { browser: t.browser, state: {}, sendToTab: async () => ({}) };
  await t.ctx.SCHandlers.handle("site.allowOnce", { domain: "Shop.Example" }, deps);
  await t.ctx.SCHandlers.handle("site.allowOnce", { domain: "mybank.example" }, deps);
  assert.deepEqual(storage.store["sc.sitesOnce"], ["shop.example", "mybank.example"]);
  assert.equal(await w.SC.sites.isAllowed("shop.example"), "allowed");
  assert.equal(await w.SC.sites.isAllowed("mybank.example"), "allowed");
  assert.equal(await w.SC.sites.isAllowed("other.example"), "ask");
  await t.ctx.SCHandlers.handle("site.clearOnce", {}, deps);
  assert.equal(await w.SC.sites.isAllowed("shop.example"), "ask");
  assert.equal(await w.SC.sites.isAllowed("mybank.example"), "denied");
  // A permanent allow is untouched by clearOnce.
  await w.SC.sites.allow("kept.example");
  await t.ctx.SCHandlers.handle("site.clearOnce", {}, deps);
  assert.equal(await w.SC.sites.isAllowed("kept.example"), "allowed");
});

test("elDescribeReturnsRoleAndName", async () => {
  const w = loadContent('<label for="q">Search</label><input id="q"><a href="/x" aria-label="Home">H</a>', []);
  let listener;
  w.browser = { runtime: { onMessage: { addListener: (f) => { listener = f; } } } };
  for (const f of ["extension/content/snapshot.js", "extension/content/main.js"]) w.eval(readFileSync(f, "utf8"));
  w.SC.snapshot("interactive");
  assert.deepEqual(j(await listener({ method: "el.describe", params: { ref: "e1" } })), { role: "textbox", name: "Search" });
  assert.deepEqual(j(await listener({ method: "el.describe", params: { ref: "e2" } })), { role: "link", name: "Home" });
  w.document.querySelector("a").remove();
  const gone = j(await listener({ method: "el.describe", params: { ref: "e2" } }));
  assert.equal(gone.error.code, "not_found");
});

test("elDescribeRoutesToAgentTab", async () => {
  const t = setup({ toTab: () => ({ role: "button", name: "Go" }) });
  const deps = { browser: t.browser, state: { agentTab: 4 }, sendToTab: (id, m) => t.browser.tabs.sendMessage(id, m) };
  assert.deepEqual(j(await t.ctx.SCHandlers.handle("el.describe", { ref: "e1" }, deps)), { role: "button", name: "Go" });
});

test("manifestDeclaresChatEntryPoints", () => {
  const m = JSON.parse(readFileSync("extension/manifest.json", "utf8"));
  assert.ok(m.permissions.includes("contextMenus"));
  assert.equal(m.commands["open-chat"].suggested_key.mac, "MacCtrl+Shift+K");
  assert.equal(m.commands["open-chat"].suggested_key.default, "MacCtrl+Shift+K");
  const bg = m.background.scripts;
  assert.ok(bg.indexOf("bg/chat.js") >= 0 && bg.indexOf("bg/chat.js") < bg.indexOf("background.js"));
});

test("backgroundScriptsAreAscii", () => {
  const files = ["extension/background.js", ...readdirSync("extension/bg").filter((f) => f.endsWith(".js")).map((f) => `extension/bg/${f}`)];
  assert.ok(files.includes("extension/bg/chat.js"));
  for (const f of files) {
    const bad = [...readFileSync(f)].findIndex((b) => b > 0x7f);
    assert.equal(bad, -1, `${f} has a non-ASCII byte at ${bad}`);
  }
});
