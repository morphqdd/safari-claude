// Chat window: opening it, relaying port <-> daemon events, confirmation cards.
(() => {
  const ports = new Set();
  const cards = new Map(); // id -> { card, kind, resolve }
  let cardSeq = 0;
  let opening = null;

  const ANSWERS = { site: ["once", "always", "no"], other: ["allow", "deny"] };
  const answers = (kind) => (kind === "site" ? ANSWERS.site : ANSWERS.other);
  const refusal = (kind) => answers(kind).at(-1);
  // "No connection to the helper"
  const NO_LINK = "\u041d\u0435\u0442 \u0441\u0432\u044f\u0437\u0438 \u0441 \u043f\u043e\u043c\u043e\u0449\u043d\u0438\u043a\u043e\u043c";

  const post = (msg) => { for (const p of ports) { try { p.postMessage(msg); } catch { /* port gone */ } } };

  // Opens the chat window flush right of the last-focused window, or focuses the open one.
  function openChat(deps) {
    opening ??= open(deps).finally(() => { opening = null; });
    return opening;
  }

  async function open({ browser, state }) {
    if (state.chatWindow != null) {
      try { await browser.windows.update(state.chatWindow, { focused: true }); return; } catch { state.chatWindow = null; }
    }
    const opts = { url: browser.runtime.getURL("chat/chat.html"), type: "popup", width: 400 };
    try {
      const last = await browser.windows.getLastFocused();
      Object.assign(opts, { height: last.height, left: last.left + last.width, top: last.top });
    } catch { /* no window: default placement */ }
    const w = await browser.windows.create(opts);
    state.chatWindow = w.id;
  }

  function onWindowRemoved(id, deps) {
    if (id !== deps.state.chatWindow) return;
    deps.state.chatWindow = null;
    // The page never connected: nobody can answer the waiting cards.
    if (ports.size === 0) refuseAll(false);
  }

  function settle(id, decision, announce) {
    const c = cards.get(id);
    if (!c) return;
    cards.delete(id);
    if (announce) post({ type: "cardClosed", id });
    c.resolve({ decision: answers(c.kind).includes(decision) ? decision : refusal(c.kind) });
  }

  function refuseAll(announce) {
    for (const [id, c] of [...cards]) settle(id, refusal(c.kind), announce);
  }

  // Only the chat page may connect; any other port (a content script, another name) is dropped.
  function onPort(port, deps) {
    const { browser } = deps;
    const prefix = browser.runtime.getURL("chat/").toLowerCase();
    const url = String(port.sender?.url ?? "").toLowerCase();
    if (port.name !== "chat" || !url.startsWith(prefix)) {
      port.disconnect();
      return;
    }
    ports.add(port);
    port.onDisconnect.addListener(() => {
      ports.delete(port);
      if (ports.size === 0) refuseAll(false);
    });
    port.onMessage.addListener((m) => onPortMessage(port, m, deps));
    for (const c of cards.values()) port.postMessage(c.card);
  }

  function onPortMessage(port, m, deps) {
    switch (m?.type) {
      case "send":
        if (!deps.sendEvent("chat.send", { text: String(m.text ?? "") })) port.postMessage({ type: "error", text: NO_LINK });
        break;
      case "new":
        deps.sendEvent("chat.new", {});
        break;
      case "stop":
        deps.sendEvent("stop", {});
        refuseAll(true);
        break;
      case "confirmReply":
        settle(m.id, m.decision, false);
        break;
    }
  }

  // Daemon `chat.*` events -> every chat port as {type: <name without "chat.">, ...data}.
  function onDaemonEvent(name, data, deps) {
    if (!String(name).startsWith("chat.")) return false;
    const type = name.slice("chat.".length);
    if (type === "turnEnd") {
      refuseAll(true);
      // The daemon also sends site.clearOnce; this covers a lost link or a crashed daemon.
      clearSitesOnce(deps);
    }
    post({ ...(data ?? {}), type });
    return true;
  }

  // Sites allowed "once" must not outlive the turn (storage.local survives restarts).
  function clearSitesOnce(deps) {
    return SCHandlers.handle("site.clearOnce", {}, deps).catch(() => {});
  }

  // Card text comes from the agent tab (host, element role and name), never from the model;
  // only the payload to be typed or pressed is shown as given.
  async function confirm(params, deps) {
    const { browser, state } = deps;
    const kind = params.kind;
    if (state.agentTab == null) return { decision: refusal(kind) };
    const tab = await browser.tabs.get(state.agentTab);
    let host = "";
    try { host = new URL(tab.url).hostname.toLowerCase(); } catch { /* not a URL */ }
    // A site card allows the domain the model named: it must be the page the owner sees.
    if (kind === "site" && (!host || String(params.domain ?? "").toLowerCase() !== host)) return { decision: "no" };
    const card = { type: "confirm", id: `c${++cardSeq}`, kind, host };
    if (params.ref) {
      const d = await SCHandlers.handle("el.describe", { ref: params.ref }, deps);
      card.element = { role: String(d.role ?? ""), name: String(d.name ?? "") };
    }
    if (params.text != null) card.text = String(params.text);
    if (params.combo != null) card.combo = String(params.combo);
    return new Promise((resolve) => {
      cards.set(card.id, { card, kind, resolve });
      if (ports.size > 0) post(card);
      else openChat(deps).catch(() => refuseAll(false));
    });
  }

  globalThis.SCChat = { openChat, onPort, onDaemonEvent, confirm, onWindowRemoved, clearSitesOnce };
})();
