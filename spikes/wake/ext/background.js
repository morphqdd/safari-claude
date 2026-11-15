// Spike: connect to the probe server on wake, report lifetime, run capture/mark commands.
globalThis.browser ??= globalThis.chrome;
const URL_ = 'ws://127.0.0.1:47822';
const born = Date.now();
let ws = null;

// Plain HTTP side channel, independent of the WebSocket.
function http(obj) {
  fetch('http://127.0.0.1:47822/log', { method: 'POST', body: JSON.stringify({ sw: true, ...obj }) }).catch(() => {});
}
http({ event: 'sw-loaded', hasCommands: !!browser.commands, hasAction: !!browser.action });
self.addEventListener('error', (e) => http({ event: 'sw-error', message: String(e.message) }));

function connect(reason) {
  http({ event: 'connect-called', reason });
  if (ws && ws.readyState <= 1) { send({ log: 'already-open', reason }); return; }
  try { ws = new WebSocket(URL_); } catch (err) { http({ event: 'ws-throw', error: String(err) }); return; }
  ws.onerror = () => http({ event: 'ws-error' });
  ws.onopen = () => send({ log: 'open', reason, swAgeMs: Date.now() - born });
  ws.onmessage = async (e) => {
    let cmd;
    try { cmd = JSON.parse(e.data); } catch { return; }
    try { send({ log: 'result', cmd, result: await run(cmd) }); }
    catch (err) { send({ log: 'error', cmd, error: String(err) }); }
  };
  ws.onclose = (e) => { http({ event: 'ws-close', code: e.code }); ws = null; };
}

function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ t: Date.now(), ...obj })); }

async function run(cmd) {
  if (cmd.op === 'capture') {
    const wins = await browser.windows.getAll({ populate: true });
    const out = [];
    for (const w of wins) {
      const active = w.tabs.find(t => t.active);
      try {
        const url = await browser.tabs.captureVisibleTab(w.id, { format: 'png' });
        out.push({ windowId: w.id, focused: w.focused, title: active?.title, ok: true, bytes: url.length });
      } catch (err) {
        out.push({ windowId: w.id, focused: w.focused, title: active?.title, ok: false, error: String(err) });
      }
    }
    return out;
  }
  if (cmd.op === 'mark') {
    const tabs = await browser.tabs.query({ url: 'http://127.0.0.1/*' });
    const res = [];
    for (const t of tabs) {
      const r = await browser.scripting.executeScript({
        target: { tabId: t.id },
        func: (cls) => { const b = document.getElementById('btn'); b?.classList.add(cls); return !!b; },
        args: [cmd.cls]
      });
      res.push({ tabId: t.id, active: t.active, marked: r[0]?.result });
    }
    return res;
  }
  if (cmd.op === 'age') return { swAgeMs: Date.now() - born };
  return 'unknown';
}

browser.commands.onCommand.addListener((name) => { http({ event: 'onCommand', name }); connect('command:' + name); });
browser.action.onClicked.addListener(() => { http({ event: 'onClicked' }); connect('action'); });
