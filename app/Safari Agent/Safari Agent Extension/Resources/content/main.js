// Content-script dispatcher: background messages -> SC.* (top frame only).
(() => {
  if (window.top !== window) return;
  const SC = (globalThis.SC ??= {});
  if (SC.mainInstalled) return;
  SC.mainInstalled = true;

  const table = {
    "page.snapshot": (p) => ({ text: SC.snapshot(p.filter || "interactive") }),
    "page.find": (p) => ({ matches: SC.find(p.query) }),
    "page.text": (p) => ({ text: SC.text(p.ref) }),
    "page.scroll": (p) => { SC.scroll(p); return {}; },
    "el.prepare": (p) => SC.prepare(p.ref, p.action),
    "el.release": (p) => { SC.release(p.ref); return {}; },
    "el.submitRisk": (p) => SC.submitRisk(p.ref),
    "el.domClick": (p) => { SC.domClick(p.ref); return {}; },
    "el.focus": (p) => ({ focused: SC.focus(p.ref) }),
    "el.domType": (p) => ({ value: SC.domType(p.ref, p.text) }),
    "el.domKey": (p) => { SC.domKey(p.combo); return {}; },
    "el.value": (p) => ({ value: SC.value(p.ref) }),
    "site.allow": async (p) => { await SC.sites.allow(p.domain); return {}; },
    "overlay.status": (p) => { SC.overlay?.status(p.text); return {}; },
    navigate: (p) => {
      if (p.action === "back") history.back();
      else if (p.action === "forward") history.forward();
      else if (p.action === "reload") location.reload();
      else throw { code: "bad_request", message: "navigate: unknown action" };
      return {};
    },
  };

  browser.runtime.onMessage.addListener((msg) => {
    const fn = msg && table[msg.method];
    if (!fn) return undefined;
    return (async () => fn(msg.params ?? {}))().catch((e) => ({
      error: e && typeof e.code === "string"
        ? { code: e.code, message: String(e.message ?? "") }
        : { code: "internal", message: String(e?.message ?? e) },
    }));
  });
})();
