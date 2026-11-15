// Daemon requests -> browser.tabs calls or content-script messages.
(() => {
  const CONTENT_FILES = [
    "content/snapshot.js", "content/risk.js", "content/sites.js",
    "content/overlay.js", "content/actions.js", "content/main.js",
  ];
  const NO_RECEIVER = /Could not establish connection|Receiving end does not exist|no receiver/i;
  const LOAD_TIMEOUT_MS = 30000;
  const SITES_ONCE = "sc.sitesOnce"; // hosts allowed for the current chat turn (read by content/sites.js)
  const err = (code, message) => ({ code, message });

  const CONTENT_METHODS = new Set([
    "page.snapshot", "page.find", "page.text", "page.scroll",
    "el.prepare", "el.release", "el.submitRisk", "el.domClick", "el.focus",
    "el.domType", "el.domKey", "el.value", "el.describe", "site.allow", "site.check", "overlay.status",
  ]);

  // Safe to re-send: they only read page state (page.scroll and everything that acts is excluded).
  const IDEMPOTENT = new Set([
    "page.snapshot", "page.find", "page.text", "el.prepare", "el.release", "el.value", "el.describe",
    "el.submitRisk", "site.check", "overlay.status",
  ]);

  function agent(deps) {
    const id = deps.state.agentTab;
    if (id == null) throw err("no_agent_tab", "\u041d\u0435\u0442 \u0432\u043a\u043b\u0430\u0434\u043a\u0438 \u0430\u0433\u0435\u043d\u0442\u0430: \u0432\u044b\u0437\u043e\u0432\u0438\u0442\u0435 tab_create \u0438\u043b\u0438 tab_select");
    return id;
  }

  // Only http(s) pages and about:blank may be opened.
  function checkURL(url) {
    if (url === "about:blank") return;
    let protocol = null;
    try { protocol = new URL(url).protocol; } catch { /* not a URL */ }
    if (protocol !== "http:" && protocol !== "https:") {
      throw err("bad_request", "\u0420\u0430\u0437\u0440\u0435\u0448\u0435\u043d\u044b \u0442\u043e\u043b\u044c\u043a\u043e \u0430\u0434\u0440\u0435\u0441\u0430 http, https \u0438 about:blank");
    }
  }

  // Switches the agent tab; the old tab's overlay is hidden (best-effort).
  function setAgent(deps, id) {
    const old = deps.state.agentTab;
    deps.state.agentTab = id;
    if (old != null && old !== id) {
      Promise.resolve()
        .then(() => deps.sendToTab(old, { method: "overlay.status", params: { text: null } }))
        .catch(() => {});
    }
  }

  async function toContent(deps, tabId, method, params) {
    const msg = { method, params };
    // Safari may resolve undefined (instead of rejecting) when no content script listens. That is
    // retried only for read-only methods: after an acting method the page may have navigated and
    // torn the port down, so an undefined reply there is treated as success without a re-send.
    let injected = false;
    const inject = async () => {
      injected = true;
      for (const file of CONTENT_FILES) {
        await deps.browser.tabs.executeScript(tabId, { file, allFrames: true });
      }
      return deps.sendToTab(tabId, msg);
    };
    let res;
    try {
      res = await deps.sendToTab(tabId, msg);
    } catch (e) {
      if (!NO_RECEIVER.test(String(e?.message ?? e))) throw e;
      res = await inject();
    }
    if (res == null) {
      if (!IDEMPOTENT.has(method)) return {};
      if (!injected) res = await inject();
      if (res == null) throw err("internal", "content script not available in this tab (restricted page?)");
    }
    if (res.error) throw res.error;
    return res;
  }

  const NO_LOAD_MS = 3000;

  // `start()` performs the navigation and returns the tab id. The onUpdated listener is armed
  // first. Resolves after a `loading` (or url change) followed by `complete`; if no loading
  // starts within 3 s the navigation is treated as same-document/no-op and resolves anyway.
  // `fresh` (new tab): a `complete` alone is enough, including one seen before create returned,
  // but not the initial about:blank one (unless `allowBlank`).
  function whenLoaded(browser, start, { fresh = false, allowBlank = false } = {}) {
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
          hardTimer = setTimeout(() => finish(reject, err("timeout", "\u0421\u0442\u0440\u0430\u043d\u0438\u0446\u0430 \u043d\u0435 \u0437\u0430\u0433\u0440\u0443\u0437\u0438\u043b\u0430\u0441\u044c \u0437\u0430 30 \u0441")), LOAD_TIMEOUT_MS);
        }
      };
      const see = (info) => {
        if (info.status === "loading" || info.url !== undefined) {
          loading = true;
          clearTimeout(idleTimer);
          armHard();
        }
        if (info.status === "complete") {
          if (fresh) freshComplete();
          else if (loading) finish(resolve);
        }
      };
      const freshComplete = async () => {
        try {
          const t = await browser.tabs.get(tabId);
          if (t.status !== "complete") return;
          if (allowBlank || t.url !== "about:blank") finish(resolve);
        } catch { /* tab gone: the hard timer reports it */ }
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
            await freshComplete();
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
        if (params.url) { checkURL(params.url); opts.url = params.url; }
        const make = async () => {
          const tab = await browser.tabs.create(opts);
          setAgent(deps, tab.id);
          return tab.id;
        };
        if (!params.url) return { tabId: await make() };
        await whenLoaded(browser, make, { fresh: true, allowBlank: params.url === "about:blank" });
        return { tabId: state.agentTab };
      }
      case "tabs.select": {
        try {
          await browser.tabs.get(params.tabId);
        } catch {
          throw err("not_found", `\u0412\u043a\u043b\u0430\u0434\u043a\u0430 ${params.tabId} \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u0430`);
        }
        setAgent(deps, params.tabId);
        return {};
      }
      case "tab.state": {
        const id = agent(deps);
        const t = await browser.tabs.get(id);
        // windows.get(...).focused is false for every window when Safari is not the active app.
        const last = await browser.windows.getLastFocused();
        return { tabId: id, url: t.url, title: t.title, activeInWindow: !!t.active, windowFocused: last.id === t.windowId };
      }
      case "navigate": {
        const id = agent(deps);
        if (params.url) {
          checkURL(params.url);
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
          throw err("bad_request", "navigate: \u043d\u0443\u0436\u0435\u043d url \u0438\u043b\u0438 action");
        }
        return urlTitle(browser, id);
      }
      case "tab.screenshot": {
        const id = agent(deps);
        const t = await browser.tabs.get(id);
        if (!t.active) throw err("background_tab", "\u0412\u043a\u043b\u0430\u0434\u043a\u0430 \u0430\u0433\u0435\u043d\u0442\u0430 \u0432 \u0444\u043e\u043d\u0435: \u0441\u043a\u0440\u0438\u043d\u0448\u043e\u0442 \u043d\u0435\u0432\u043e\u0437\u043c\u043e\u0436\u0435\u043d");
        return { dataUrl: await browser.tabs.captureVisibleTab(t.windowId, { format: "png" }) };
      }
      case "site.allowOnce": {
        const host = String(params.domain ?? "").toLowerCase();
        if (!host) throw err("bad_request", "site.allowOnce: domain is required");
        const got = await browser.storage.local.get(SITES_ONCE);
        const hosts = Array.isArray(got?.[SITES_ONCE]) ? got[SITES_ONCE] : [];
        if (!hosts.includes(host)) hosts.push(host);
        await browser.storage.local.set({ [SITES_ONCE]: hosts });
        return {};
      }
      case "site.clearOnce":
        await browser.storage.local.set({ [SITES_ONCE]: [] });
        return {};
      default:
        if (CONTENT_METHODS.has(method)) return toContent(deps, agent(deps), method, params);
        throw err("bad_request", `\u041d\u0435\u0438\u0437\u0432\u0435\u0441\u0442\u043d\u044b\u0439 \u043c\u0435\u0442\u043e\u0434 ${method}`);
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
