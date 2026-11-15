// WebSocket link to the helper daemon. Reconnects with backoff; no pings.
(() => {
  const URL_ = "ws://127.0.0.1:47821";
  const BACKOFF = [1000, 2000, 5000, 15000, 30000];
  let ws = null;
  let attempt = 0;

  const isConnected = () => !!(ws && ws.readyState === 1);
  const send = (obj) => {
    if (!isConnected()) return false;
    ws.send(JSON.stringify(obj));
    return true;
  };

  async function onReq(m) {
    try {
      const result = await SCLink.onRequest(m.method, m.params ?? {});
      send({ type: "res", id: m.id, result: result ?? {} });
    } catch (e) {
      const error = e && typeof e.code === "string"
        ? { code: e.code, message: String(e.message ?? "") }
        : { code: "internal", message: String(e?.message ?? e) };
      send({ type: "res", id: m.id, error });
    }
  }

  const SCLink = (globalThis.SCLink = {
    onRequest: async () => ({}),
    onEvent: () => {},
    // Called on every close, including failed reconnect attempts.
    onClose: () => {},
    connect() {
      let sock;
      try {
        sock = new WebSocket(URL_);
      } catch {
        schedule();
        return;
      }
      ws = sock;
      sock.onopen = () => sock.send(JSON.stringify({ type: "hello", role: "extension" }));
      sock.onmessage = (e) => {
        let m;
        try { m = JSON.parse(e.data); } catch { return; }
        if (m.type === "welcome") attempt = 0;
        else if (m.type === "req") onReq(m);
        else if (m.type === "event") SCLink.onEvent(m.name, m.data ?? {});
      };
      sock.onclose = () => {
        if (ws === sock) ws = null;
        SCLink.onClose();
        schedule();
      };
    },
    isConnected,
    sendEvent(name, data = {}) {
      return send({ type: "event", name, data });
    },
  });

  function schedule() {
    const ms = BACKOFF[Math.min(attempt, BACKOFF.length - 1)];
    attempt++;
    setTimeout(() => SCLink.connect(), ms);
  }
})();
