(() => {
  const SC = (globalThis.SC ??= {});
  if (SC.snapshot) return;

  const INTERACTIVE = [
    "a[href]", "button", "input", "textarea", "select", "summary",
    "[contenteditable]", "[onclick]",
    ...["button", "link", "checkbox", "radio", "tab", "menuitem", "option", "switch", "textbox", "combobox"]
      .map((r) => `[role="${r}"]`),
  ].join(",");
  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"]);
  const BUTTON_INPUTS = new Set(["submit", "button", "reset"]);

  let refs = new Map();

  const collapse = (s) => (s ?? "").replace(/\s+/g, " ").trim();
  const esc = (s) => s.replace(/"/g, '\\"');
  const textOf = (el) => collapse(el.innerText ?? el.textContent);

  function roleOf(el) {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit;
    const tag = el.tagName.toLowerCase();
    const type = (el.getAttribute("type") || "text").toLowerCase();
    if (tag === "a" && el.hasAttribute("href")) return "link";
    if (tag === "button" || tag === "summary") return "button";
    if (tag === "input") {
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      if (BUTTON_INPUTS.has(type)) return "button";
      return "textbox";
    }
    if (tag === "textarea") return "textbox";
    if (tag === "select") return "combobox";
    if (el.hasAttribute("contenteditable")) return "textbox";
    return "button";
  }

  function nameOf(el) {
    const doc = el.ownerDocument;
    const aria = collapse(el.getAttribute("aria-label"));
    if (aria) return aria.slice(0, 80);
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const t = collapse(by.split(/\s+/).map((id) => doc.getElementById(id)?.textContent ?? "").join(" "));
      if (t) return t.slice(0, 80);
    }
    const label = el.labels?.[0] ?? el.closest("label");
    if (label) {
      const t = collapse(label.textContent);
      if (t) return t.slice(0, 80);
    }
    for (const a of ["alt", "title", "placeholder"]) {
      const v = collapse(el.getAttribute(a));
      if (v) return v.slice(0, 80);
    }
    const t = textOf(el);
    if (t) return t.slice(0, 80);
    if (el.tagName === "INPUT" && BUTTON_INPUTS.has((el.type || "").toLowerCase())) return collapse(el.value).slice(0, 80);
    return "";
  }

  function isHidden(el) {
    if (el.hidden || el.getAttribute("aria-hidden") === "true") return true;
    const cs = el.ownerDocument.defaultView?.getComputedStyle(el);
    return !!cs && (cs.display === "none" || cs.visibility === "hidden");
  }

  function describe(el, role, name) {
    let line = `[ref=${""}] ${role} "${esc(name)}"`;
    const tag = el.tagName;
    const type = (el.getAttribute("type") || "").toLowerCase();
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
      const isToggle = type === "checkbox" || type === "radio" || BUTTON_INPUTS.has(type);
      if (!isToggle && el.value) {
        line += ` value="${type === "password" ? "••••" : esc(String(el.value))}"`;
      }
    }
    const checked = (tag === "INPUT" && (type === "checkbox" || type === "radio") && el.checked) ||
      el.getAttribute("aria-checked") === "true";
    if (checked) line += " checked";
    if (el.disabled || el.getAttribute("aria-disabled") === "true") line += " disabled";
    if (tag === "A" && el.hasAttribute("href")) line += ` href="${esc(el.getAttribute("href"))}"`;
    return line;
  }

  function collect(filter) {
    const out = [];
    const newRefs = new Map();
    let n = 0;

    const children = (node, depth, inside) => {
      for (const c of node.childNodes) visit(c, depth, inside);
    };

    function visit(node, depth, inside) {
      if (node.nodeType === 3) {
        if (filter === "all" && !inside) {
          const t = collapse(node.nodeValue);
          if (t) out.push({ line: `- text "${esc(t.slice(0, 200))}"`, depth: 0 });
        }
        return;
      }
      if (node.nodeType !== 1 || SKIP.has(node.tagName) || isHidden(node)) return;

      let d = depth, inc = inside;
      if (node.matches(INTERACTIVE)) {
        const ref = `e${++n}`;
        const role = roleOf(node);
        const name = nameOf(node);
        newRefs.set(ref, new WeakRef(node));
        out.push({
          line: describe(node, role, name).replace("[ref=]", `[ref=${ref}]`),
          depth, ref, role, name, el: node,
        });
        d = depth + 1;
        inc = true;
      }
      if (node.shadowRoot) children(node.shadowRoot, d, inc);
      if (node.tagName === "IFRAME" || node.tagName === "FRAME") {
        let doc = null;
        try { doc = node.contentDocument; } catch { /* cross-origin */ }
        if (doc?.documentElement) visit(doc.documentElement, d, inc);
      }
      children(node, d, inc);
    }

    visit(document.documentElement, 0, false);
    refs = newRefs;
    return out;
  }

  SC.snapshot = (filter = "interactive") =>
    collect(filter).map((e) => "  ".repeat(e.depth) + e.line).join("\n");

  function isLive(el) {
    if (!el.isConnected) return false;
    let win = el.ownerDocument.defaultView;
    while (win) {
      let frame;
      try { frame = win.frameElement; } catch { return false; }
      if (!frame) return true;
      if (!frame.isConnected) return false;
      win = frame.ownerDocument.defaultView;
    }
    return false;
  }

  SC.resolve = (ref) => {
    const el = refs.get(ref)?.deref();
    return el && isLive(el) ? el : null;
  };

  SC.find = (query) => {
    const q = String(query).toLowerCase();
    return collect("interactive")
      .filter((e) => e.name.toLowerCase().includes(q) || textOf(e.el).toLowerCase().includes(q))
      .map(({ ref, role, name }) => ({ ref, role, name }));
  };

  SC.text = (ref) => {
    const el = ref ? SC.resolve(ref) : document.body;
    if (!el) return "";
    return collapse(el.innerText ?? el.textContent).slice(0, 50000);
  };
})();
