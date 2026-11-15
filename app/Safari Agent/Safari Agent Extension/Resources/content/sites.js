(() => {
  const SC = (globalThis.SC ??= {});
  if (SC.sites) return;

  const KEY = "sc.sites";
  const DENY = ["bank", "sber", "tbank", "tinkoff", "vtb", "alfabank", "gosuslugi", "nalog.gov", "paypal", "1password", "bitwarden", "lastpass"];
  let cache = null;

  async function load() {
    if (cache) return cache;
    const got = await browser.storage.local.get(KEY);
    const allowed = got?.[KEY]?.allowed;
    cache = new Set(Array.isArray(allowed) ? allowed : []);
    return cache;
  }

  SC.sites = {
    async isAllowed(hostname) {
      const host = String(hostname).toLowerCase();
      if ((await load()).has(host)) return "allowed";
      if (DENY.some((d) => host.includes(d))) return "denied";
      return "ask";
    },
    async allow(hostname) {
      const set = await load();
      set.add(String(hostname).toLowerCase());
      await browser.storage.local.set({ [KEY]: { allowed: [...set] } });
    },
  };
})();
