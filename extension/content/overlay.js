// Visual overlay: Claude cursor, element highlight, status bar with «Стоп».
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
    host.style.cssText = "position:fixed;inset:0;z-index:2147483647;pointer-events:none;";
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
    stop.addEventListener("click", () => {
      stop.disabled = true;
      label.textContent = "Остановлено";
      st.stopped = true;
      try { browser.runtime.sendMessage({ event: "stop" }); } catch {}
    });
    document.documentElement.appendChild(host);
    st = { host, hl, cur, label, stop, x: null, y: null, origTitle: document.title, timers: new Set(), stopped: false };
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
      st.host.remove();
      const t = document.title;
      document.title = t.startsWith("● ") ? t.slice(2) : t;
      st = null;
      return;
    }
    if (!st) mount();
    if (!st.stopped) st.label.textContent = "Claude: " + text;
    if (!document.title.startsWith("● ")) document.title = "● " + document.title;
  }

  function doMove(r) {
    if (!st) mount();
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
    return new Promise((res) => later(res, FLY_MS));
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

  function forward(msg) {
    try { window.top.postMessage({ __sc_overlay: msg }, "*"); } catch {}
  }

  if (isTop) {
    window.addEventListener("message", (ev) => {
      const m = ev.data && typeof ev.data === "object" ? ev.data.__sc_overlay : null;
      if (!m || typeof m.op !== "string") return;
      if (m.op === "status") doStatus(typeof m.text === "string" ? m.text : null);
      else if (m.op === "pulse") doPulse();
      else if (m.op === "moveTo" && m.rect) {
        let dx = 0, dy = 0;
        for (const f of document.querySelectorAll("iframe,frame")) {
          if (f.contentWindow === ev.source) {
            const b = f.getBoundingClientRect();
            dx = b.left; dy = b.top;
            break;
          }
        }
        const r = m.rect;
        doMove({ left: r.left + dx, top: r.top + dy, width: r.width, height: r.height });
      }
    });
  }

  SC.overlay = {
    status(text) {
      if (isTop) doStatus(text);
      else forward({ op: "status", text: text ?? null });
    },
    moveTo(el) {
      if (isTop) return doMove(rectOf(el));
      forward({ op: "moveTo", rect: rectOf(el) });
      return new Promise((res) => setTimeout(res, FLY_MS));
    },
    pulse() {
      if (isTop) doPulse();
      else forward({ op: "pulse" });
    },
    _stopButtonForTest() { return st?.stop ?? null; },
  };
})();
