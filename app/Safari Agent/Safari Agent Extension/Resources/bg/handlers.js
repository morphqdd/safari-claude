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

  const NO_LOAD_MS = 3000;

  // `start()` performs the navigation and returns the tab id. The onUpdated listener is armed
  // first. Resolves after a `loading` (or url change) followed by `complete`; if no loading
  // starts within 3 s the navigation is treated as same-document/no-op and resolves anyway.
  // `fresh` (new tab): a `complete` alone is enough, including one seen before create returned.
  function whenLoaded(browser, start, { fresh = false } = {}) {
    return new Promise((resolve, reject) => {
      let tabId = null;
      let loading = false;
      let done = false;
      let idleTimer = null;
      let hardTimer = null;
      const early = [];
      const finish = (fn, v) => {
        if (done) return;
        done = true;
        clearTimeout(idleTimer);
        clearTimeout(hardTimer);
        browser.tabs.onUpdated.removeListener(on);
        fn(v);
      };
      const armHard = () => {
        if (hardTimer == null) {
          hardTimer = setTimeout(() => finish(reject, err("timeout", "Страница не загрузилась за 30 с")), LOAD_TIMEOUT_MS);
        }
      };
      const see = (info) => {
        if (info.status === "loading" || info.url !== undefined) {
          loading = true;
          clearTimeout(idleTimer);
          armHard();
        }
        if (info.status === "complete" && (loading || fresh)) finish(resolve);
      };
      function on(id, info) {
        if (tabId == null) early.push([id, info]);
        else if (id === tabId) see(info);
      }
      browser.tabs.onUpdated.addListener(on);
      Promise.resolve()
        .then(start)
        .then(async (id) => {
          tabId = id;
          for (const [eid, info] of early) if (eid === id) see(info);
          if (done) return;
          if (fresh) {
            armHard();
            if ((await browser.tabs.get(id)).status === "complete") finish(resolve);
          } else if (!loading) {
            idleTimer = setTimeout(() => finish(resolve), NO_LOAD_MS);
          }
        })
        .catch((e) => finish(reject, e));
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
        const make = async () => {
          const tab = await browser.tabs.create(opts);
          state.agentTab = tab.id;
          return tab.id;
        };
        if (!params.url) return { tabId: await make() };
        await whenLoaded(browser, make, { fresh: true });
        return { tabId: state.agentTab };
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
          await whenLoaded(browser, async () => { await browser.tabs.update(id, { url: params.url }); return id; });
        } else if (["back", "forward", "reload"].includes(params.action)) {
          await whenLoaded(browser, async () => {
            if (params.action === "reload" && browser.tabs.reload) {
              await browser.tabs.reload(id);
            } else {
              // The page may unload before replying; a lost reply is not a failure.
              try {
                const res = await deps.sendToTab(id, { method: "navigate", params: { action: params.action } });
                if (res && res.error) throw res.error;
              } catch (e) {
                if (e && typeof e.code === "string") throw e;
              }
            }
            return id;
          });
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
