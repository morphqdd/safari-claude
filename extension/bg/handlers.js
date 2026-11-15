// Daemon requests -> browser.tabs calls or content-script messages.
(() => {
  const CONTENT_FILES = [
    "content/snapshot.js", "content/risk.js", "content/sites.js",
    "content/overlay.js", "content/actions.js", "content/main.js",
  ];
  const NO_RECEIVER = /Could not establish connection|Receiving end does not exist|no receiver/i;
  const LOAD_TIMEOUT_MS = 30000;
  const err = (code, message) => ({ code, message });

  const CONTENT_METHODS = new Set([
    "page.snapshot", "page.find", "page.text", "page.scroll",
    "el.prepare", "el.release", "el.submitRisk", "el.domClick", "el.focus",
    "el.domType", "el.domKey", "el.value", "site.allow", "overlay.status",
  ]);

  function agent(deps) {
    const id = deps.state.agentTab;
    if (id == null) throw err("no_agent_tab", "Нет вкладки агента: вызовите tabs_create или tabs_select");
    return id;
  }

  async function toContent(deps, tabId, method, params) {
    const msg = { method, params };
    let res;
    try {
      res = await deps.sendToTab(tabId, msg);
    } catch (e) {
      if (!NO_RECEIVER.test(String(e?.message ?? e))) throw e;
      for (const file of CONTENT_FILES) {
        await deps.browser.tabs.executeScript(tabId, { file, allFrames: true });
      }
      res = await deps.sendToTab(tabId, msg);
    }
    if (res && res.error) throw res.error;
    return res ?? {};
  }

  // Resolves once `tabId` reports status "complete"; `start` is invoked after the listener is armed.
  function whenLoaded(browser, tabId, start) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        browser.tabs.onUpdated.removeListener(on);
        reject(err("timeout", "Страница не загрузилась за 30 с"));
      }, LOAD_TIMEOUT_MS);
      function on(id, info) {
        if (id !== tabId || info.status !== "complete") return;
        clearTimeout(timer);
        browser.tabs.onUpdated.removeListener(on);
        resolve();
      }
      browser.tabs.onUpdated.addListener(on);
      Promise.resolve(start()).catch((e) => {
        clearTimeout(timer);
        browser.tabs.onUpdated.removeListener(on);
        reject(e);
      });
    });
  }

  async function urlTitle(browser, tabId) {
    const t = await browser.tabs.get(tabId);
    return { url: t.url, title: t.title };
  }

  async function handle(method, params, deps) {
    const { browser, state } = deps;
    params = params ?? {};
    switch (method) {
      case "tabs.list": {
        const tabs = await browser.tabs.query({});
        return {
          tabs: tabs.map((t) => ({
            tabId: t.id, windowId: t.windowId, url: t.url, title: t.title,
            active: !!t.active, isAgent: t.id === state.agentTab,
          })),
        };
      }
      case "tabs.create": {
        const win = await browser.windows.getLastFocused();
        const [active] = await browser.tabs.query({ active: true, windowId: win.id });
        const opts = { active: false };
        if (active) { opts.index = active.index + 1; opts.windowId = active.windowId; }
        if (params.url) opts.url = params.url;
        const tab = await browser.tabs.create(opts);
        state.agentTab = tab.id;
        if (params.url) await whenLoaded(browser, tab.id, () => {});
        return { tabId: tab.id };
      }
      case "tabs.select": {
        try {
          await browser.tabs.get(params.tabId);
        } catch {
          throw err("not_found", `Вкладка ${params.tabId} не найдена`);
        }
        state.agentTab = params.tabId;
        return {};
      }
      case "tab.state": {
        const id = agent(deps);
        const t = await browser.tabs.get(id);
        const w = await browser.windows.get(t.windowId);
        return { tabId: id, url: t.url, title: t.title, activeInWindow: !!t.active, windowFocused: !!w.focused };
      }
      case "navigate": {
        const id = agent(deps);
        if (params.url) {
          await whenLoaded(browser, id, () => browser.tabs.update(id, { url: params.url }));
        } else if (["back", "forward", "reload"].includes(params.action)) {
          await whenLoaded(browser, id, () => toContent(deps, id, "navigate", { action: params.action }));
        } else {
          throw err("bad_request", "navigate: нужен url или action");
        }
        return urlTitle(browser, id);
      }
      case "tab.screenshot": {
        const id = agent(deps);
        const t = await browser.tabs.get(id);
        if (!t.active) throw err("background_tab", "Вкладка агента в фоне: скриншот невозможен");
        return { dataUrl: await browser.tabs.captureVisibleTab(t.windowId, { format: "png" }) };
      }
      default:
        if (CONTENT_METHODS.has(method)) return toContent(deps, agent(deps), method, params);
        throw err("bad_request", `Неизвестный метод ${method}`);
    }
  }

  // Clears the agent tab when it is closed.
  function watch(browser, state) {
    browser.tabs.onRemoved.addListener((id) => {
      if (id === state.agentTab) state.agentTab = null;
    });
  }

  globalThis.SCHandlers = { handle, watch };
})();
