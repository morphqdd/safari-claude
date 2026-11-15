(() => {
  const SC = (globalThis.SC ??= {});
  if (SC.prepare) return;

  const err = (code, message) => ({ code, message });
  const need = (ref) => {
    const el = SC.resolve(ref);
    if (!el) throw err("not_found", `Element ${ref} is gone; call read_page again`);
    return el;
  };
  const win = (el) => el.ownerDocument.defaultView;

  // Site allow/deny gate for the agent tab's hostname.
  SC.checkSite = async () => {
    const host = location.hostname;
    if ((await SC.sites.isAllowed(host)) !== "allowed") {
      throw err("site_not_allowed", `Разрешите сайт: confirm_action kind=site domain=${host}`);
    }
    return {};
  };

  SC.prepare = async (ref, _action) => {
    const el = need(ref);
    await SC.checkSite();
    const marker = `__sc_m_${ref}`;
    clearMarker(marker);
    try {
      el.scrollIntoView({ block: "center" });
      await SC.overlay?.moveTo(el);
      el.classList.add(marker);
      return { marker, risk: SC.classifyRisk(el) };
    } catch (e) {
      clearMarker(marker);
      throw e;
    }
  };

  function clearMarker(marker, root = document) {
    for (const el of root.querySelectorAll(`.${marker}`)) el.classList.remove(marker);
    for (const el of root.querySelectorAll("*")) {
      if (el.shadowRoot) clearMarker(marker, el.shadowRoot);
      if (el.tagName === "IFRAME") {
        try {
          if (el.contentDocument) clearMarker(marker, el.contentDocument);
        } catch {}
      }
    }
  }

  SC.release = (ref) => {
    clearMarker(`__sc_m_${ref}`);
    SC.overlay?.pulse();
  };

  const isButtonLike = (el) => {
    const tag = el.tagName;
    const type = (el.getAttribute?.("type") || "").toLowerCase();
    return tag === "BUTTON" || tag === "SUMMARY" || (tag === "A" && el.hasAttribute("href")) ||
      (tag === "INPUT" && ["submit", "button", "reset", "image"].includes(type)) ||
      el.getAttribute?.("role") === "button";
  };

  SC.submitRisk = (ref) => {
    const el = ref ? need(ref) : document.activeElement;
    if (!el || el === el.ownerDocument.body || el === el.ownerDocument.documentElement) return { risky: false };
    // Enter/Space on a focused button activates that button, not the form's default submitter.
    if (isButtonLike(el)) return SC.classifyRisk(el);
    const form = el.closest?.("form") ?? el.form ?? null;
    if (!form) return SC.classifyRisk(el);
    const submitter = form.querySelector("[type=submit], button:not([type])");
    if (submitter) return SC.classifyRisk(submitter);
    return SC.formIsPayment(form) ? { risky: true, kind: "payment" } : { risky: false };
  };

  SC.domClick = (ref) => {
    const el = need(ref);
    const r = el.getBoundingClientRect();
    const init = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
    const w = win(el);
    for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      const Ctor = t.startsWith("pointer") && w.PointerEvent ? w.PointerEvent : w.MouseEvent;
      el.dispatchEvent(new Ctor(t, init));
    }
  };

  SC.focus = (ref) => {
    const el = need(ref);
    el.focus();
    return el.ownerDocument.activeElement === el;
  };

  SC.domType = (ref, text) => {
    const el = need(ref);
    const w = win(el);
    const fire = (t) => el.dispatchEvent(new w.Event(t, { bubbles: true }));
    if (el.tagName === "SELECT") {
      const opt = [...el.options].find((o) => o.text === text || o.value === text);
      if (!opt) throw err("bad_request", `No option matching "${text}"`);
      el.value = opt.value;
      fire("input");
      fire("change");
      return el.value;
    }
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      const proto = el.tagName === "INPUT" ? w.HTMLInputElement.prototype : w.HTMLTextAreaElement.prototype;
      el.focus();
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
      fire("input");
      fire("change");
      return Object.getOwnPropertyDescriptor(proto, "value").get.call(el);
    }
    if (el.isContentEditable || el.hasAttribute("contenteditable")) {
      el.focus();
      const d = el.ownerDocument;
      if (!(typeof d.execCommand === "function" && d.execCommand("insertText", false, text))) {
        el.textContent = text;
        el.dispatchEvent(new w.Event("input", { bubbles: true }));
      }
      return el.textContent;
    }
    throw err("bad_request", `Element ${ref} is not editable`);
  };

  const KEYS = {
    enter: "Enter", tab: "Tab", escape: "Escape", backspace: "Backspace", delete: "Delete",
    arrowup: "ArrowUp", arrowdown: "ArrowDown", arrowleft: "ArrowLeft", arrowright: "ArrowRight",
    home: "Home", end: "End", pageup: "PageUp", pagedown: "PageDown", space: " ",
  };
  const MODS = { cmd: "metaKey", shift: "shiftKey", alt: "altKey", ctrl: "ctrlKey" };

  SC.domKey = (combo) => {
    const parts = String(combo).split("+");
    if (parts.length > 1 && parts[parts.length - 1] === "") parts.splice(-2, 2, "+");
    const base = parts.pop();
    const init = { bubbles: true, cancelable: true, composed: true };
    for (const m of parts) {
      const f = MODS[m.toLowerCase()];
      if (!f) throw err("bad_request", `Unknown modifier "${m}" in "${combo}"`);
      init[f] = true;
    }
    const key = KEYS[base.toLowerCase()] ?? (base.length === 1 ? base : null);
    if (!key) throw err("bad_request", `Unknown key "${base}"`);
    init.key = key;
    const target = document.activeElement ?? document.body;
    const w = win(target);
    const notCancelled = target.dispatchEvent(new w.KeyboardEvent("keydown", init));
    target.dispatchEvent(new w.KeyboardEvent("keyup", init));
    if (key === "Enter" && notCancelled && target.tagName !== "TEXTAREA" && !target.isContentEditable && !target.hasAttribute?.("contenteditable")) {
      const f = target.form ?? target.closest?.("form");
      f?.requestSubmit?.();
    }
  };

  SC.value = (ref) => {
    const el = need(ref);
    return String(el.value ?? el.textContent ?? "");
  };

  SC.scroll = ({ ref, direction = "down", amount = 600 } = {}) => {
    const dx = direction === "left" ? -amount : direction === "right" ? amount : 0;
    const dy = direction === "up" ? -amount : direction === "down" ? amount : 0;
    if (ref) {
      const el = need(ref);
      if (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth) el.scrollBy({ left: dx, top: dy });
      else el.scrollIntoView({ block: "center" });
    } else {
      window.scrollBy({ left: dx, top: dy });
    }
  };
})();
