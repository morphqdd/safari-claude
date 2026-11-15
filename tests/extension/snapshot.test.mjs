import { test } from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "./helpers.mjs";
const j = (x) => JSON.parse(JSON.stringify(x));

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

test("refsStableAcrossSnapshotsAndFind", () => {
  const w = loadContent(`<button id="a">A</button><button id="b">B</button>`);
  assert.match(w.SC.snapshot("interactive"), /^\[ref=e1\] button "A"\n\[ref=e2\] button "B"$/);
  const a = w.document.getElementById("a");
  // a new node inserted before the old ones must not take over their refs
  w.document.body.insertAdjacentHTML("afterbegin", `<button id="n">A new</button>`);
  const m = j(w.SC.find("a"));
  assert.deepEqual(m, [{ ref: "e3", role: "button", name: "A new" }, { ref: "e1", role: "button", name: "A" }]);
  assert.equal(w.SC.resolve("e1"), a);
  assert.equal(w.SC.resolve("e3"), w.document.getElementById("n"));
  assert.equal(w.SC.snapshot("interactive"), ['[ref=e3] button "A new"', '[ref=e1] button "A"', '[ref=e2] button "B"'].join("\n"));
});

test("removedElementRefNeverReused", () => {
  const w = loadContent(`<button>A</button>`);
  w.SC.snapshot("interactive");
  w.document.querySelector("button").remove();
  w.document.body.insertAdjacentHTML("afterbegin", `<button>B</button>`);
  assert.equal(w.SC.snapshot("interactive"), '[ref=e2] button "B"');
  assert.equal(w.SC.resolve("e1"), null);
});

test("waitForPollingDoesNotRenumber", () => {
  const w = loadContent(`<button>Go</button>`);
  w.SC.snapshot("interactive");
  for (let i = 0; i < 3; i++) w.SC.find("nothing");
  w.document.body.insertAdjacentHTML("afterbegin", `<a href="/x">Go too</a>`);
  w.SC.find("go");
  assert.equal(w.SC.resolve("e1"), w.document.querySelector("button"));
});
