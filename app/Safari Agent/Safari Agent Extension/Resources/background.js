globalThis.browser ??= globalThis.chrome;

const state = { agentTab: null, chatWindow: null };
const sendToTab = (tabId, msg) => browser.tabs.sendMessage(tabId, msg, { frameId: 0 });
const sendEvent = (name, data) => SCLink.sendEvent(name, data);
const deps = { browser, sendToTab, sendEvent, state };
const openChat = () => { SCChat.openChat(deps).catch(() => {}); };

SCHandlers.watch(browser, state);
// No turn survives a background restart, so neither do its "once" sites.
SCChat.clearSitesOnce(deps);
SCLink.onRequest = (method, params) =>
  method === "chat.confirm" ? SCChat.confirm(params, deps) : SCHandlers.handle(method, params, deps);
SCLink.onEvent = (name, data) => {
  if (SCChat.onDaemonEvent(name, data, deps)) return;
  if (name === "idle" && state.agentTab != null) {
    sendToTab(state.agentTab, { method: "overlay.status", params: { text: null } }).catch(() => {});
  }
};
SCLink.onClose = () => SCChat.onLinkLost(deps);
browser.runtime.onMessage.addListener((msg) => {
  if (msg && msg.event === "stop") return Promise.resolve({ ok: !!SCLink.sendEvent("stop", {}) });
  return undefined;
});
browser.runtime.onConnect?.addListener((port) => SCChat.onPort(port, deps));
browser.windows?.onRemoved?.addListener((id) => SCChat.onWindowRemoved(id, deps));

// Toolbar button, shortcut and page context menu open the chat. Stop lives in the chat and the overlay.
browser.browserAction?.onClicked?.addListener(openChat);
browser.commands?.onCommand?.addListener((name) => { if (name === "open-chat") openChat(); });
if (browser.contextMenus) {
  // ASCII only: Safari garbles non-ASCII menu titles.
  // removeAll first: a background reload would otherwise hit a duplicate-id error.
  Promise.resolve()
    .then(() => browser.contextMenus.removeAll?.())
    .catch(() => {})
    .then(() => browser.contextMenus.create(
      { id: "ask-page", title: "Ask Claude about this page", contexts: ["page"] },
      () => void browser.runtime.lastError,
    ))
    .catch(() => {});
  browser.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId !== "ask-page") return;
    if (tab?.id != null) sendEvent("chat.askPage", { tabId: tab.id });
    openChat();
  });
}
SCLink.connect();
