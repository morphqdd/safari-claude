// Chat window page: transcript, input, confirmation cards. All text goes in via textContent.
(() => {
  const KEY = "sc.chat";
  const KINDS = ["user", "assistant", "action", "notice", "error"];
  const BACKOFF = [500, 1000, 2000, 5000]; // ms; the last value repeats
  const LOST = "Связь с расширением прервалась";
  const BUSY = "Занято другой сессией";

  const SITE = [["once", "Один раз"], ["always", "Всегда"], ["no", "Нет"]];
  const OTHER = [["allow", "Разрешить"], ["deny", "Отказать"]];
  const LABELS = Object.fromEntries([...SITE, ...OTHER]);
  const TITLE = { site: "Открыть сайт", click: "Нажать", type: "Ввести текст", key: "Нажать клавишу" };

  const hostOf = (u) => { try { return new URL(u).hostname; } catch { return String(u ?? ""); } };
  const quoted = (s) => `«${s}»`;

  // Short Russian line for an action; unknown tools fall back to the bare tool name.
  function describe(tool, input = {}) {
    const t = String(tool).replace(/^mcp__safari__/, "");
    const ref = input.ref ?? input.element ?? "";
    switch (t) {
      case "navigate": return `открыл ${hostOf(input.url)}`;
      case "click": return `нажал ${ref}`.trim();
      case "type": return `ввёл ${quoted(input.text ?? "")}`;
      case "key": return `нажал клавишу ${input.combo ?? input.key ?? ""}`.trim();
      case "scroll": return "прокрутил страницу";
      case "snapshot": return "посмотрел страницу";
      case "screenshot": return "сделал снимок";
      default: return t;
    }
  }

  async function init(doc, browser) {
    const $ = (id) => doc.getElementById(id);
    const log = $("log"), input = $("input"), send = $("send"), stop = $("stop");
    let entries = [];
    let current = null; // assistant entry being streamed
    let currentEl = null;
    let waiting = false;
    const cards = new Map(); // id -> { el, resolved }

    const save = async () => {
      try { await browser.storage.local.set({ [KEY]: { entries } }); } catch { /* storage unavailable */ }
    };
    const setWaiting = (v) => { waiting = v; send.disabled = v; };
    const stick = () => { log.scrollTop = log.scrollHeight; };

    function line(kind, text) {
      const el = doc.createElement("div");
      el.className = kind;
      el.textContent = text;
      log.appendChild(el);
      stick();
      return el;
    }
    function add(kind, text) {
      entries.push({ kind, text });
      current = null;
      line(kind, text);
      save();
    }

    try {
      const got = await browser.storage.local.get(KEY);
      const saved = got?.[KEY]?.entries;
      if (Array.isArray(saved)) {
        entries = saved
          .filter((e) => e && KINDS.includes(e.kind) && typeof e.text === "string")
          .map((e) => ({ kind: e.kind, text: e.text }));
        for (const e of entries) line(e.kind, e.text);
      }
    } catch { /* start empty */ }

    let port = null;
    let attempt = 0; // reconnects since the last message from the background
    const later = doc.defaultView.setTimeout.bind(doc.defaultView);
    function reconnectSoon() {
      later(connect, BACKOFF[Math.min(attempt, BACKOFF.length - 1)]);
      attempt++;
    }
    function connect() {
      try {
        const p = browser.runtime.connect({ name: "chat" });
        port = p;
        p.onMessage.addListener((m) => { attempt = 0; onMessage(m); });
        p.onDisconnect.addListener(() => {
          if (port === p) port = null;
          if (waiting) { add("error", LOST); setWaiting(false); }
          reconnectSoon(); // the background re-sends pending cards on connect
        });
      } catch {
        port = null;
        reconnectSoon();
      }
    }
    const post = (m) => { try { port?.postMessage(m); } catch { /* port gone: reconnect is scheduled */ } };

    function submit() {
      const text = input.value.trim();
      if (!text || waiting) return;
      input.value = "";
      add("user", text);
      setWaiting(true);
      post({ type: "send", text });
    }

    function closeCard(id, answer) {
      const c = cards.get(id);
      if (!c || c.resolved) return;
      c.resolved = true;
      c.el.querySelector(".buttons").remove();
      const a = doc.createElement("div");
      a.className = "answer";
      a.textContent = answer;
      c.el.appendChild(a);
    }

    function showCard(m) {
      if (cards.has(m.id)) return;
      const el = doc.createElement("div");
      el.className = "card";
      const row = (cls, text) => {
        const d = doc.createElement("div");
        d.className = cls;
        d.textContent = text;
        el.appendChild(d);
      };
      row("title", `${TITLE[m.kind] ?? "Подтвердите"}: ${m.host ?? ""}`);
      if (m.element) row("detail", `${m.element.role ?? ""} ${quoted(m.element.name ?? "")}`.trim());
      if (m.text != null) row("detail", quoted(m.text));
      if (m.combo != null) row("detail", String(m.combo));
      const buttons = doc.createElement("div");
      buttons.className = "buttons";
      for (const [decision, label] of m.kind === "site" ? SITE : OTHER) {
        const b = doc.createElement("button");
        b.type = "button";
        b.textContent = label;
        b.addEventListener("click", () => {
          post({ type: "confirmReply", id: m.id, decision });
          closeCard(m.id, LABELS[decision]);
        });
        buttons.appendChild(b);
      }
      el.appendChild(buttons);
      log.appendChild(el);
      cards.set(m.id, { el, resolved: false });
      stick();
    }

    function onMessage(m) {
      switch (m?.type) {
        case "delta":
          if (!current) {
            current = { kind: "assistant", text: "" };
            entries.push(current);
            currentEl = line("assistant", "");
          }
          current.text += String(m.text ?? "");
          currentEl.textContent = current.text;
          stick();
          break;
        case "action": add("action", `· ${describe(m.tool, m.input)}`); break;
        case "notice": add("notice", String(m.text ?? "")); break;
        case "error": add("error", String(m.text ?? "")); setWaiting(false); break;
        case "busy": add("error", BUSY); setWaiting(false); break;
        case "turnEnd": current = null; setWaiting(false); save(); break;
        case "confirm": showCard(m); break;
        case "cardClosed": closeCard(m.id, "Отказано"); break;
      }
    }
    connect();

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        submit();
      }
    });
    send.addEventListener("click", submit);
    stop.addEventListener("click", () => post({ type: "stop" }));
    $("new").addEventListener("click", () => {
      entries = [];
      current = null;
      cards.clear();
      log.textContent = "";
      setWaiting(false);
      save();
      post({ type: "new" });
    });
  }

  globalThis.SCChatPage = { init };
  const b = globalThis.browser ?? globalThis.chrome;
  if (b?.runtime?.connect) init(document, b);
})();
