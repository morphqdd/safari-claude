import { test } from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "./helpers.mjs";

const BASIC = `<button>Найти</button><a href="/x">Ссылка</a><input aria-label="Поиск">`;

test("snapshotListsInteractive", () => {
  const w = loadContent(BASIC);
  assert.equal(
    w.SC.snapshot("interactive"),
    ['[ref=e1] button "Найти"', '[ref=e2] link "Ссылка" href="/x"', '[ref=e3] textbox "Поиск"'].join("\n"),
  );
});

test("snapshotSkipsHidden", () => {
  const w = loadContent(`<button hidden>X</button><div aria-hidden="true"><button>Y</button></div><div style="display:none"><button>Z</button></div><button>ok</button>`);
  assert.equal(w.SC.snapshot("interactive"), '[ref=e1] button "ok"');
});

test("snapshotIncludesShadowAndIframe", () => {
  const w = loadContent(`<div id="h"></div><iframe id="f"></iframe>`);
  const root = w.document.getElementById("h").attachShadow({ mode: "open" });
  root.innerHTML = "<button>InShadow</button>";
  const f = w.document.getElementById("f");
  // jsdom does not load srcdoc; populate the same-origin about:blank frame directly.
  f.contentDocument.body.innerHTML = "<button>InFrame</button>";
  const s = w.SC.snapshot("interactive");
  assert.match(s, /\[ref=e\d+\] button "InShadow"/);
  assert.match(s, /\[ref=e\d+\] button "InFrame"/);
});

test("resolveReturnsElement", () => {
  const w = loadContent(BASIC);
  w.SC.snapshot("interactive");
  assert.equal(w.SC.resolve("e1"), w.document.querySelector("button"));
  assert.equal(w.SC.resolve("e99"), null);
});

test("resolveNullWhenDisconnected", () => {
  const w = loadContent(BASIC);
  w.SC.snapshot("interactive");
  w.document.querySelector("button").remove();
  assert.equal(w.SC.resolve("e1"), null);
});

test("findMatchesName", () => {
  const w = loadContent(BASIC);
  assert.deepEqual(JSON.parse(JSON.stringify(w.SC.find("найти"))), [{ ref: "e1", role: "button", name: "Найти" }]);
});

test("valuesPasswordCheckedDisabledEscape", () => {
  const w = loadContent(`<input aria-label="u" value="bob"><input type="password" aria-label="p" value="s3"><input type="checkbox" aria-label="c" checked><button disabled>Say "hi"</button>`);
  assert.equal(
    w.SC.snapshot("interactive"),
    [
      '[ref=e1] textbox "u" value="bob"',
      '[ref=e2] textbox "p" value="••••"',
      '[ref=e3] checkbox "c" checked',
      '[ref=e4] button "Say \\"hi\\"" disabled',
    ].join("\n"),
  );
});

test("nameFromLabelAndPlaceholder", () => {
  const w = loadContent(`<label for="a">Email</label><input id="a"><label>Zip <input></label><input placeholder="Q"><span id="l">Lbl</span><button aria-labelledby="l">x</button>`);
  const s = w.SC.snapshot("interactive").split("\n");
  assert.equal(s[0], '[ref=e1] textbox "Email"');
  assert.match(s[1], /textbox "Zip"/);
  assert.equal(s[2], '[ref=e3] textbox "Q"');
  assert.equal(s[3], '[ref=e4] button "Lbl"');
});

test("nestedIndentAndAllText", () => {
  const w = loadContent(`<p>Hello   world</p><div role="button">Outer <a href="#">In</a></div>`);
  assert.equal(
    w.SC.snapshot("all"),
    ['- text "Hello world"', '[ref=e1] button "Outer In"', '  [ref=e2] link "In" href="#"'].join("\n"),
  );
});

test("textReturnsCollapsed", () => {
  const w = loadContent(`<p>a   b</p><button>c</button>`);
  assert.equal(w.SC.text(), "a bc");
  w.SC.snapshot("interactive");
  assert.equal(w.SC.text("e1"), "c");
});

test("loadingTwiceIsSafe", async () => {
  const w = loadContent(BASIC, ["extension/content/snapshot.js", "extension/content/snapshot.js"]);
  assert.equal(w.SC.snapshot("interactive").split("\n").length, 3);
});

function shadowAndFrame() {
  const w = loadContent(`<div id="h"></div><iframe id="f"></iframe>`);
  w.document.getElementById("h").attachShadow({ mode: "open" }).innerHTML = "<button>InShadow</button>";
  w.document.getElementById("f").contentDocument.body.innerHTML = "<button>InFrame</button>";
  w.SC.snapshot("interactive");
  return w;
}

test("resolveReachesShadowAndIframeElements", () => {
  const w = shadowAndFrame();
  assert.equal(w.SC.resolve("e1").textContent, "InShadow");
  assert.equal(w.SC.resolve("e2").textContent, "InFrame");
});

test("resolveNullAfterShadowHostRemoved", () => {
  const w = shadowAndFrame();
  w.document.getElementById("h").remove();
  assert.equal(w.SC.resolve("e1"), null);
});

test("resolveNullAfterIframeRemoved", () => {
  const w = shadowAndFrame();
  w.document.getElementById("f").remove();
  assert.equal(w.SC.resolve("e2"), null);
});
