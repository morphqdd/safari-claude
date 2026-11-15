import { test } from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "./helpers.mjs";

const FILES = ["extension/content/snapshot.js", "extension/content/risk.js", "extension/content/sites.js", "extension/content/actions.js"];

function load(html) {
  const w = loadContent(html, []);
  const store = {};
  w.browser = {
    storage: {
      local: {
        get: async (k) => (k in store ? { [k]: store[k] } : {}),
        set: async (o) => void Object.assign(store, o),
      },
    },
  };
  return loadContent2(w, FILES);
}
import { readFileSync } from "node:fs";
function loadContent2(w, files) {
  for (const f of files) w.eval(readFileSync(f, "utf8"));
  return w;
}
const risk = (html, sel = "button") => {
  const w = load(html);
  return JSON.parse(JSON.stringify(w.SC.classifyRisk(w.document.querySelector(sel))));
};

test("riskPayment", () => assert.deepEqual(risk("<button>Оплатить</button>"), { risky: true, kind: "payment" }));
test("riskSend", () => assert.deepEqual(risk("<button>Send</button>"), { risky: true, kind: "send" }));
test("riskDelete", () => assert.deepEqual(risk("<button>Удалить</button>"), { risky: true, kind: "delete" }));
test("riskSafe", () => assert.equal(risk("<button>Найти</button>").risky, false));
test("riskCardForm", () =>
  assert.equal(risk(`<form><input name="cardNumber"><button>Далее</button></form>`).kind, "payment"));
test("riskLoginSubmit", () =>
  assert.deepEqual(risk(`<form><input type="password"><button type="submit">Go</button></form>`, "button"), { risky: true, kind: "payment" }));
test("riskPasswordSubmitRuleE", () => {
  // password field makes rule (a) fire first; rule (e) is unreachable for a form with a password field but kept per spec
  assert.equal(risk(`<form><input type="password"><input type="submit" value="Go"></form>`, "input[type=submit]").risky, true);
});

test("submitRiskOfPaymentForm", () => {
  const w = load(`<form><input id="a"><button type="submit">Оплатить</button></form>`);
  w.document.getElementById("a").focus();
  assert.deepEqual(JSON.parse(JSON.stringify(w.SC.submitRisk())), { risky: true, kind: "payment" });
});
test("submitRiskSearchForm", () => {
  const w = load(`<form><input id="a"><button type="submit">Найти</button></form>`);
  w.document.getElementById("a").focus();
  assert.equal(w.SC.submitRisk().risky, false);
});

test("deniedSite", async () => {
  const w = load("");
  assert.equal(await w.SC.sites.isAllowed("online.sberbank.ru"), "denied");
  assert.equal(await w.SC.sites.isAllowed("example.com"), "ask");
  await w.SC.sites.allow("example.com");
  assert.equal(await w.SC.sites.isAllowed("example.com"), "allowed");
  await w.SC.sites.allow("online.sberbank.ru");
  assert.equal(await w.SC.sites.isAllowed("online.sberbank.ru"), "allowed");
});
