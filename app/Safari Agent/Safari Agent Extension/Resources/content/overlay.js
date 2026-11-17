// Visual overlay: Claude cursor, element highlight, status bar with «Стоп» and «×» (hide).
// Idle-zero: nothing is mounted until the first status/moveTo.
(() => {
  const SC = (globalThis.SC ??= {});
  const COLOR = "#D97757";
  const FLY_MS = 350;
  const PULSE_MS = 300;
  const isTop = window.top === window;

  const CSS = `
    :host { all: initial; }
    * { box-sizing: border-box; font-family: -apple-system, system-ui, sans-serif; }
    .glow { position: fixed; inset: 0; pointer-events: none;
      box-shadow: inset 0 0 40px 6px rgba(217,119,87,.35); }
    .hl { position: fixed; display: none; border: 2px solid ${COLOR}; border-radius: 6px;
      pointer-events: none; transition: all ${FLY_MS}ms ease; }
    .cur { position: fixed; left: 0; top: 0; display: none; pointer-events: none;
      transition: transform ${FLY_MS}ms ease; color: ${COLOR}; font-size: 12px; font-weight: 600; }
    .cur svg { display: block; }
    .cur span { position: absolute; left: 16px; top: 16px; background: ${COLOR}; color: #fff;
      padding: 1px 6px; border-radius: 8px; white-space: nowrap; }
    .ring { position: absolute; left: -12px; top: -12px; width: 24px; height: 24px; border-radius: 50%;
      border: 2px solid ${COLOR}; animation: sc-pulse ${PULSE_MS}ms ease-out forwards; }
    @keyframes sc-pulse { from { transform: scale(.3); opacity: 1; } to { transform: scale(1.8); opacity: 0; } }
    .bar { position: fixed; left: 50%; bottom: 16px; transform: translateX(-50%); display: flex;
      align-items: center; gap: 10px; padding: 8px 12px; border-radius: 999px; background: #1f1f1f;
      color: #fff; font-size: 13px; box-shadow: 0 4px 16px rgba(0,0,0,.35); pointer-events: none; }
    .dot { color: ${COLOR}; }
    button { pointer-events: auto; cursor: pointer; border: 0; border-radius: 999px; padding: 3px 12px;
      background: ${COLOR}; color: #fff; font-size: 12px; font-weight: 600; }
    button:disabled { opacity: .5; cursor: default; }
    button.hide { background: transparent; color: #aaa; padding: 3px 6px; font-size: 14px; }
    @media (prefers-reduced-motion: reduce) {
      .hl, .cur { transition: none; }
      .ring { animation: none; }
    }`;

  let st = null; // mounted state

  const reduced = () => !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  const mk = (tag, cls, parent) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    parent?.appendChild(e);
    return e;
  };

  function mount() {
    const host = document.createElement("div");
    host.id = "__sc_overlay";
    const hs = {
      position: "fixed", top: "0", right: "0", bottom: "0", left: "0", width: "auto", height: "auto",
      margin: "0", padding: "0", border: "0", "z-index": "2147483647", "pointer-events": "none",
      display: "block", visibility: "visible", opacity: "1", transform: "none", filter: "none",
    };
    for (const k in hs) host.style.setProperty(k, hs[k], "important");
    const root = host.attachShadow({ mode: "closed" });
    const style = mk("style", null, root);
    style.textContent = CSS;
    mk("div", "glow", root);
    const hl = mk("div", "hl", root);
    const cur = mk("div", "cur", root);
    cur.innerHTML = `<svg width="18" height="18" viewBox="0 0 18 18"><path d="M2 1 L16 8 L9 10 L7 17 Z" fill="${COLOR}" stroke="#fff" stroke-width="1"/></svg>`;
    mk("span", null, cur).textContent = "Claude";
    const bar = mk("div", "bar", root);
    mk("span", "dot", bar).textContent = "●";
    const label = mk("span", "txt", bar);
    const stop = mk("button", null, bar);
    stop.textContent = "Стоп";
    stop.addEventListener("click", async () => {
      if (stop.disabled) return;
      stop.disabled = true;
      try {
        const r = await browser.runtime.sendMessage({ event: "stop" });
        if (!r || r.ok !== true) throw new Error("stop not delivered");
        label.textContent = "Остановлено";
        st.stopped = true;
      } catch {
        label.textContent = "Не удалось остановить";
        stop.disabled = false;
      }
    });
    const hide = mk("button", "hide", bar);
    hide.textContent = "×";
    hide.title = "Скрыть до конца работы агента";
    hide.addEventListener("click", () => { st.dismissed = true; applyVisibility(); });
    document.documentElement.appendChild(host);
    st = { host, hl, cur, label, stop, hide, x: null, y: null, origTitle: document.title, timers: new Set(), pending: new Set(),
      stopped: false, dismissed: false, capturing: false };
  }

  // Hidden while a screenshot is taken or after the owner pressed «×» (until the session ends).
  function applyVisibility() {
    if (!st) return;
    st.host.style.setProperty("visibility", st.dismissed || st.capturing ? "hidden" : "visible", "important");
  }

  // Resolves once the hidden overlay has been painted out (two frames; timer fallback if rAF is throttled).
  function painted() {
    return new Promise((res) => {
      const t = setTimeout(res, 100);
      const raf = window.requestAnimationFrame;
      if (!raf) return;
      raf(() => raf(() => { clearTimeout(t); res(); }));
    });
  }

  function doCapture(hidden) {
    if (!st) return Promise.resolve();
    st.capturing = hidden;
    applyVisibility();
    return hidden ? painted() : Promise.resolve();
  }

  // Mounts on first use; re-attaches the host if the page removed it.
  function ensureMounted() {
    if (!st) mount();
    else if (!st.host.isConnected) document.documentElement.appendChild(st.host);
  }

  function later(fn, ms) {
    const id = setTimeout(() => { st?.timers.delete(id); fn(); }, ms);
    st?.timers.add(id);
    return id;
  }

  function doStatus(text) {
    if (text == null) {
      if (!st) return;
      for (const t of st.timers) clearTimeout(t);
      for (const r of st.pending) r();
      st.host.remove();
      const t = document.title;
      document.title = t.startsWith("● ") ? t.slice(2) : t;
      st = null;
      return;
    }
    ensureMounted();
    if (!st.stopped) st.label.textContent = "Claude: " + text;
    if (!document.title.startsWith("● ")) document.title = "● " + document.title;
  }

  function doMove(r) {
    ensureMounted();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    const first = st.x === null;
    const { cur, hl } = st;
    if (first) {
      const sx = window.innerWidth - 40, sy = window.innerHeight - 40;
      const prev = cur.style.transition;
      cur.style.transition = "none";
      cur.style.display = "block";
      cur.style.transform = `translate(${sx}px,${sy}px)`;
      void cur.offsetWidth;
      cur.style.transition = prev;
    }
    const hlPrev = hl.style.transition;
    if (hl.style.display !== "block") hl.style.transition = "none";
    hl.style.display = "block";
    hl.style.left = r.left - 3 + "px";
    hl.style.top = r.top - 3 + "px";
    hl.style.width = r.width + 6 + "px";
    hl.style.height = r.height + 6 + "px";
    void hl.offsetWidth;
    hl.style.transition = hlPrev;
    cur.style.display = "block";
    cur.style.transform = `translate(${cx}px,${cy}px)`;
    st.x = cx; st.y = cy;
    if (reduced()) return Promise.resolve();
    return new Promise((res) => {
      const s = st;
      const done = () => { s.pending.delete(done); res(); };
      s.pending.add(done);
      later(done, FLY_MS);
    });
  }

  function doPulse() {
    if (!st || st.x === null || reduced()) return;
    const ring = mk("div", "ring", st.cur);
    later(() => ring.remove(), PULSE_MS);
  }

  const rectOf = (el) => {
    const r = el.getBoundingClientRect();
    return { left: r.left, top: r.top, width: r.width, height: r.height };
  };

  // Subframes are no-ops: the overlay lives only in the top frame (no page-spoofable channel).
  SC.overlay = {
    status(text) { if (isTop) doStatus(text); },
    moveTo(el) { return isTop ? doMove(rectOf(el)) : Promise.resolve(); },
    pulse() { if (isTop) doPulse(); },
    capture(hidden) { return isTop ? doCapture(!!hidden) : Promise.resolve(); },
    _stopButtonForTest() { return st?.stop ?? null; },
    _dismissButtonForTest() { return st?.hide ?? null; },
  };
})();
