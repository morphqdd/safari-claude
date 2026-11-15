import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const tick = () => new Promise((r) => setImmediate(r));
const j = (x) => JSON.parse(JSON.stringify(x));

async function page(stored) {
  const html = readFileSync("extension/chat/chat.html", "utf8");
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "safari-web-extension://ABCD/chat/chat.html" });
  const w = dom.window;
  w.eval(readFileSync("extension/chat/chat.js", "utf8"));
  const store = stored ? { "sc.chat": j(stored) } : {};
  const sent = [];
  let onMsg, onDis, connects = 0;
  const browser = {
    runtime: { connect: (o) => {
      assert.equal(o.name, "chat");
      connects++;
      return {
        postMessage: (m) => sent.push(j(m)),
        onMessage: { addListener: (f) => { onMsg = f; } },
        onDisconnect: { addListener: (f) => { onDis = f; } },
      };
    } },
    storage: { local: {
      get: async (k) => (k in store ? { [k]: j(store[k]) } : {}),
      set: async (o) => void Object.assign(store, j(o)),
    } },
  };
  await w.SCChatPage.init(w.document, browser);
  const d = w.document;
  const $ = (s) => d.querySelector(s);
  const push = async (m) => { onMsg(m); await tick(); };
  const type = async (text) => { $("#input").value = text; };
  const key = (k, shiftKey = false) => {
    const e = new w.KeyboardEvent("keydown", { key: k, shiftKey, bubbles: true, cancelable: true });
    $("#input").dispatchEvent(e);
    return e;
  };
  const drop = async () => { onDis(); await tick(); };
  return { drop, connects: () => connects, w, d, $, store, sent, push, type, key };
}

test("sendPostsMessageAndDisablesInput", async () => {
  const p = await page();
  await p.type("привет");
  const e = p.key("Enter");
  await tick();
  assert.ok(e.defaultPrevented);
  assert.deepEqual(p.sent, [{ type: "send", text: "привет" }]);
  assert.equal(p.$("#send").disabled, true);
  assert.equal(p.$("#input").value, "");
  assert.match(p.$("#log").textContent, /привет/);
  // Enter while busy sends nothing
  await p.type("ещё");
  p.key("Enter");
  assert.equal(p.sent.length, 1);
  await p.push({ type: "turnEnd" });
  assert.equal(p.$("#send").disabled, false);
});

test("shiftEnterIsNewline", async () => {
  const p = await page();
  await p.type("a");
  const e = p.key("Enter", true);
  assert.equal(e.defaultPrevented, false);
  assert.equal(p.sent.length, 0);
});

test("deltasStreamIntoOneEntry", async () => {
  const p = await page();
  await p.push({ type: "delta", text: "Откр" });
  await p.push({ type: "delta", text: "ываю" });
  assert.equal(p.d.querySelectorAll(".assistant").length, 1);
  assert.equal(p.$(".assistant").textContent, "Открываю");
  await p.push({ type: "action", tool: "mcp__safari__navigate", input: { url: "https://example.com/x" } });
  await p.push({ type: "delta", text: "Готово" });
  assert.equal(p.d.querySelectorAll(".assistant").length, 2);
});

test("actionAndNoticeLines", async () => {
  const p = await page();
  await p.push({ type: "action", tool: "mcp__safari__navigate", input: { url: "https://example.com/x" } });
  await p.push({ type: "action", tool: "mcp__safari__click", input: { ref: "e12" } });
  await p.push({ type: "notice", text: "Сессия сброшена" });
  await p.push({ type: "error", text: "Сбой" });
  const acts = [...p.d.querySelectorAll(".action")].map((e) => e.textContent);
  assert.equal(acts[0], "· открыл example.com");
  assert.equal(acts[1], "· нажал e12");
  assert.equal(p.$(".notice").textContent, "Сессия сброшена");
  assert.equal(p.$(".error").textContent, "Сбой");
  assert.deepEqual(p.store["sc.chat"].entries.map((e) => e.kind), ["action", "action", "notice", "error"]);
});

test("busyReenablesInput", async () => {
  const p = await page();
  await p.type("x");
  p.key("Enter");
  await tick();
  await p.push({ type: "busy" });
  assert.match(p.$("#log").textContent, /Занято другой сессией/);
  assert.equal(p.$("#send").disabled, false);
});

test("errorReenablesInput", async () => {
  const p = await page();
  await p.type("x");
  p.key("Enter");
  await tick();
  await p.push({ type: "error", text: "boom" });
  assert.equal(p.$("#send").disabled, false);
});

test("siteCardHasThreeButtons", async () => {
  const p = await page();
  await p.push({ type: "confirm", id: "c1", kind: "site", host: "rzd.ru" });
  const labels = [...p.d.querySelectorAll(".card button")].map((b) => b.textContent);
  assert.deepEqual(labels, ["Один раз", "Всегда", "Нет"]);
  assert.match(p.$(".card").textContent, /rzd\.ru/);
});

test("clickCardHasTwoButtons", async () => {
  const p = await page();
  await p.push({ type: "confirm", id: "c2", kind: "click", host: "rzd.ru", element: { role: "button", name: "Купить" } });
  const labels = [...p.d.querySelectorAll(".card button")].map((b) => b.textContent);
  assert.deepEqual(labels, ["Разрешить", "Отказать"]);
  assert.match(p.$(".card").textContent, /Купить/);
  await p.push({ type: "confirm", id: "c3", kind: "type", host: "h.ru", text: "Москва" });
  assert.match(p.d.querySelectorAll(".card")[1].textContent, /Москва/);
  await p.push({ type: "confirm", id: "c4", kind: "key", host: "h.ru", combo: "Meta+Enter" });
  assert.match(p.d.querySelectorAll(".card")[2].textContent, /Meta\+Enter/);
});

test("cardReplyPostsDecision", async () => {
  const p = await page();
  await p.push({ type: "confirm", id: "c1", kind: "site", host: "rzd.ru" });
  p.d.querySelectorAll(".card button")[1].click();
  assert.deepEqual(p.sent.at(-1), { type: "confirmReply", id: "c1", decision: "always" });
  assert.equal(p.d.querySelectorAll(".card button").length, 0);
  assert.match(p.$(".card").textContent, /Всегда/);
});

test("resentCardIsNotDuplicated", async () => {
  const p = await page();
  const c = { type: "confirm", id: "c1", kind: "click", host: "a.ru" };
  await p.push(c);
  await p.push(c);
  assert.equal(p.d.querySelectorAll(".card").length, 1);
});

test("cardClosedDisablesAndShowsDeclined", async () => {
  const p = await page();
  await p.push({ type: "confirm", id: "c1", kind: "click", host: "a.ru" });
  await p.push({ type: "cardClosed", id: "c1" });
  assert.equal(p.d.querySelectorAll(".card button").length, 0);
  assert.match(p.$(".card").textContent, /Отказано/);
  assert.equal(p.sent.length, 0);
});

test("transcriptPersistsAndRestores", async () => {
  const p = await page();
  await p.type("привет");
  p.key("Enter");
  await tick();
  await p.push({ type: "delta", text: "Здравствуйте" });
  await p.push({ type: "turnEnd" });
  const saved = p.store["sc.chat"];
  assert.deepEqual(saved.entries, [
    { kind: "user", text: "привет" },
    { kind: "assistant", text: "Здравствуйте" },
  ]);
  const q = await page(saved);
  assert.equal(q.$(".user").textContent, "привет");
  assert.equal(q.$(".assistant").textContent, "Здравствуйте");
});

test("newChatClearsAndPosts", async () => {
  const p = await page({ entries: [{ kind: "user", text: "старое" }] });
  assert.match(p.$("#log").textContent, /старое/);
  p.$("#new").click();
  await tick();
  assert.deepEqual(p.sent.at(-1), { type: "new" });
  assert.equal(p.$("#log").textContent, "");
  assert.deepEqual(p.store["sc.chat"], { entries: [] });
  assert.equal(p.$("#send").disabled, false);
});

test("stopPostsStop", async () => {
  const p = await page();
  p.$("#stop").click();
  assert.deepEqual(p.sent.at(-1), { type: "stop" });
});

test("modelTextIsNotParsedAsHTML", async () => {
  const p = await page();
  await p.push({ type: "delta", text: "<img src=x onerror=alert(1)><b>hi</b>" });
  await p.push({ type: "confirm", id: "c1", kind: "type", host: "<i>h</i>", text: "<script>x</script>" });
  assert.equal(p.d.querySelectorAll("#log img, #log b, #log i, #log script").length, 0);
  assert.equal(p.$(".assistant").textContent, "<img src=x onerror=alert(1)><b>hi</b>");
});

test("restoreDropsInvalidEntries", async () => {
  const p = await page({ entries: [
    { kind: "user", text: "ok" },
    { kind: "x y\" onclick=", text: "bad" },
    { kind: "assistant", text: 5 },
    null,
    { kind: "notice", text: "n" },
  ] });
  assert.equal(p.d.querySelectorAll("#log > div").length, 2);
  assert.equal(p.$(".user").textContent, "ok");
  assert.equal(p.$(".notice").textContent, "n");
});

test("portDisconnectReconnectsAndEndsWaiting", async () => {
  const p = await page();
  await p.type("x");
  p.key("Enter");
  await tick();
  await p.drop();
  assert.equal(p.connects(), 2);
  assert.match(p.$(".error").textContent, /Связь с расширением прервалась/);
  assert.equal(p.$("#send").disabled, false);
  await p.drop();
  assert.equal(p.connects(), 3);
  assert.equal(p.d.querySelectorAll(".error").length, 1);
});

test("deltasAreSavedOnTurnEndNotPerToken", async () => {
  const p = await page();
  await p.push({ type: "delta", text: "a" });
  assert.equal(p.store["sc.chat"], undefined);
  await p.push({ type: "turnEnd" });
  assert.equal(p.store["sc.chat"].entries[0].text, "a");
});
