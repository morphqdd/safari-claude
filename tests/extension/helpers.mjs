import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

export function loadContent(html, files = ["extension/content/snapshot.js"]) {
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://example.com/" });
  for (const f of files) dom.window.eval(readFileSync(f, "utf8"));
  return dom.window;
}
