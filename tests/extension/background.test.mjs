import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

function loadLink() {
  const socks = [];
  class WS {
    constructor() { this.readyState = 0; this.sent = []; socks.push(this); }
    send(s) { this.sent.push(JSON.parse(s)); }
  }
  const ctx = vm.createContext({ console, JSON, Promise, setTimeout, WebSocket: WS });
  vm.runInContext(readFileSync("extension/bg/link.js", "utf8"), ctx);
  return { ctx, socks };
}

test("linkIsConnectedAndSendEventResult", () => {
  const { ctx, socks } = loadLink();
  const L = ctx.SCLink;
  assert.equal(L.isConnected(), false);
  assert.equal(L.sendEvent("stop", {}), false);
  L.connect();
  socks[0].readyState = 1;
  assert.equal(L.isConnected(), true);
  assert.equal(L.sendEvent("stop", {}), true);
  assert.equal(socks[0].sent.at(-1).name, "stop");
  socks[0].readyState = 3;
  assert.equal(L.isConnected(), false);
});

function loadBackground(connected) {
  let listener;
  const sent = [];
  const ctx = vm.createContext({
    console, Promise,
    browser: {
      runtime: { onMessage: { addListener: (f) => (listener = f) } },
    },
    SCHandlers: { watch() {}, handle() {} },
    SCChat: {},
    SCLink: {
      connect() {},
      sendEvent(n, d) { if (!connected) return false; sent.push([n, d]); return true; },
    },
  });
  vm.runInContext(readFileSync("extension/background.js", "utf8"), ctx);
  return { listener, sent };
}

test("backgroundStopConnected", async () => {
  const { listener, sent } = loadBackground(true);
  const r = await listener({ event: "stop" });
  assert.equal(sent.length, 1);
  assert.equal(r.ok, true);
});

test("backgroundStopDisconnected", async () => {
  const { listener, sent } = loadBackground(false);
  const r = await listener({ event: "stop" });
  assert.equal(sent.length, 0);
  assert.equal(r.ok, false);
});

test("backgroundIgnoresOtherMessages", () => {
  const { listener } = loadBackground(true);
  assert.equal(listener({ x: 1 }), undefined);
});
