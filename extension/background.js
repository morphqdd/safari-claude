globalThis.browser ??= globalThis.chrome;

const state = { agentTab: null };
const sendToTab = (tabId, msg) => browser.tabs.sendMessage(tabId, msg, { frameId: 0 });
const deps = { browser, sendToTab, state };

SCHandlers.watch(browser, state);
SCLink.onRequest = (method, params) => SCHandlers.handle(method, params, deps);
SCLink.onEvent = (name) => {
  if (name === "idle" && state.agentTab != null) {
    sendToTab(state.agentTab, { method: "overlay.status", params: { text: null } }).catch(() => {});
  }
};
browser.runtime.onMessage.addListener((msg) => {
  if (msg && msg.event === "stop") return Promise.resolve({ ok: !!SCLink.sendEvent("stop", {}) });
  return undefined;
});
SCLink.connect();
