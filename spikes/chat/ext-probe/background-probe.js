// SPIKE probes (temporary).
const P = (o) => fetch("http://127.0.0.1:47830/log", { method: "POST", body: JSON.stringify(o) }).catch(() => {});
P({ ev: "loaded", contextMenus: !!browser.contextMenus, menus: !!browser.menus, commands: !!browser.commands, windowsCreate: !!browser.windows?.create });
let chatWin = null;
async function openChat(src, tab) {
  try {
    const last = await browser.windows.getLastFocused();
    if (chatWin != null) { try { await browser.windows.update(chatWin, { focused: true }); P({ ev: "focused-existing", src }); return; } catch (e) { P({ ev: "update-failed", e: String(e) }); } }
    const w = await browser.windows.create({ url: browser.runtime.getURL("chat/probe.html"), type: "popup", width: 400, height: last.height, left: last.left + last.width, top: last.top });
    chatWin = w.id;
    P({ ev: "created", src, tabId: tab?.id, tabUrl: tab?.url, win: { id: w.id, type: w.type, width: w.width, height: w.height, left: w.left, top: w.top }, last: { width: last.width, height: last.height, left: last.left, top: last.top } });
  } catch (e) { P({ ev: "create-error", src, e: String(e) }); }
}
browser.windows.onRemoved?.addListener((id) => { if (id === chatWin) { chatWin = null; P({ ev: "chat-closed" }); } });
browser.browserAction.onClicked.addListener((tab) => openChat("toolbar", tab));
browser.commands?.onCommand.addListener((name, tab) => openChat("command:" + name, tab));
try {
  (browser.contextMenus ?? browser.menus).create({ id: "ask-page", title: "Спросить Claude про эту страницу", contexts: ["page"] });
  (browser.contextMenus ?? browser.menus).onClicked.addListener((info, tab) => openChat("menu:" + info.menuItemId, tab));
} catch (e) { P({ ev: "menu-error", e: String(e) }); }
browser.runtime.onConnect.addListener((port) => { P({ ev: "port", name: port.name, senderUrl: port.sender?.url, senderTab: port.sender?.tab?.id ?? null }); });
