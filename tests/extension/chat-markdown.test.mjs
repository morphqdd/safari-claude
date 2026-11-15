import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

function md(text) {
  const w = new JSDOM("<!doctype html><body></body>", { runScripts: "outside-only" }).window;
  w.eval(readFileSync("extension/chat/markdown.js", "utf8"));
  const box = w.document.createElement("div");
  box.appendChild(w.SCMarkdown.render(w.document, text));
  return box;
}

test("rendersBoldItalicCode", () => {
  const b = md("a **bold** and *it* and _un_ and `x < y`");
  assert.equal(b.querySelector("strong").textContent, "bold");
  assert.deepEqual([...b.querySelectorAll("em")].map((e) => e.textContent), ["it", "un"]);
  assert.equal(b.querySelector("code").textContent, "x < y");
  assert.equal(b.querySelectorAll("p").length, 1);
});

test("rendersListsAndHeadings", () => {
  const b = md("# T\n## U\n### V\n\n- a\n* b\n\n1. one\n2. two\n\nline1\nline2");
  assert.deepEqual([...b.querySelectorAll("h1,h2,h3")].map((e) => e.tagName), ["H1", "H2", "H3"]);
  const ul = b.querySelector("ul");
  assert.deepEqual([...ul.children].map((e) => e.textContent), ["a", "b"]);
  assert.deepEqual([...b.querySelectorAll("ol > li")].map((e) => e.textContent), ["one", "two"]);
  assert.equal(b.querySelector("p br") !== null, true);
});

test("rendersFencedCode", () => {
  const b = md("before\n```js\nconst **a** = 1;\n\nx\n```\nafter");
  const pre = b.querySelector("pre");
  assert.equal(pre.textContent, "const **a** = 1;\n\nx");
  assert.equal(pre.querySelector("strong"), null);
  assert.equal(b.querySelectorAll("p").length, 2);
});

test("httpLinkBecomesSafeAnchor", () => {
  const b = md("see [site](https://example.com/a?b=1) and [h](http://x.org)");
  const [a, h] = b.querySelectorAll("a");
  assert.equal(a.getAttribute("href"), "https://example.com/a?b=1");
  assert.equal(a.getAttribute("target"), "_blank");
  assert.equal(a.getAttribute("rel"), "noopener noreferrer");
  assert.equal(a.textContent, "site");
  assert.equal(h.getAttribute("href"), "http://x.org/");
});

test("javascriptLinkStaysText", () => {
  for (const u of ["javascript:alert(1)", "data:text/html,x", "/rel", "JaVaScRiPt:alert(1)", " javascript:1"]) {
    const b = md(`[click](${u})`);
    assert.equal(b.querySelector("a"), null, u);
    assert.match(b.textContent, /click/);
  }
});

test("htmlInTextIsNotParsed", () => {
  const b = md("<img src=x onerror=alert(1)> and **<script>x</script>**");
  assert.equal(b.querySelector("img"), null);
  assert.equal(b.querySelector("script"), null);
  assert.match(b.textContent, /<img src=x onerror=alert\(1\)>/);
});

test("unclosedMarkupIsLiteral", () => {
  for (const t of ["**open", "*a", "`code", "[x](http://a", "[x]", "```\nnever closed", "_ _ ** `"]) {
    const b = md(t);
    assert.equal(b.querySelector("strong,em,a"), null, t);
    assert.ok(b.textContent.includes(t.replace(/^```\n/, "")), t);
  }
  assert.doesNotThrow(() => md(""));
  assert.doesNotThrow(() => md(null));
});
