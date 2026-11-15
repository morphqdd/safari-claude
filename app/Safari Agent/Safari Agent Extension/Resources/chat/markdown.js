// Safe Markdown subset for assistant text. Model text is untrusted: only DOM nodes are built
// (createElement/createTextNode), never HTML strings, and only http(s) links become anchors.
(() => {
  const safeUrl = (s) => {
    try {
      const u = new URL(s.trim());
      return u.protocol === "http:" || u.protocol === "https:" ? u.href : null;
    } catch { return null; }
  };

  // Inline spans, scanned left to right; anything unmatched stays literal text.
  function inline(doc, parent, s) {
    let buf = "";
    const flush = () => { if (buf) { parent.appendChild(doc.createTextNode(buf)); buf = ""; } };
    const wrap = (tag, text) => {
      flush();
      const el = doc.createElement(tag);
      if (tag === "code") el.textContent = text; else inline(doc, el, text);
      parent.appendChild(el);
    };
    let i = 0;
    while (i < s.length) {
      const c = s[i];
      let end;
      if (c === "`" && (end = s.indexOf("`", i + 1)) > i + 1) {
        wrap("code", s.slice(i + 1, end)); i = end + 1; continue;
      }
      if (c === "*" && s[i + 1] === "*" && (end = s.indexOf("**", i + 2)) > i + 2) {
        wrap("strong", s.slice(i + 2, end)); i = end + 2; continue;
      }
      if ((c === "*" || c === "_") && s[i + 1] !== " " && s[i + 1] !== c
          && (c === "*" || i === 0 || !/\w/.test(s[i - 1]))) {
        end = s.indexOf(c, i + 1);
        if (end > i + 1 && s[end - 1] !== " " && (c === "*" || !/\w/.test(s[end + 1] ?? ""))) {
          wrap("em", s.slice(i + 1, end)); i = end + 1; continue;
        }
      }
      if (c === "[") {
        const m = /^\[([^\]]+)\]\(([^)\s]+)\)/.exec(s.slice(i));
        const href = m && safeUrl(m[2]);
        if (href) {
          flush();
          const a = doc.createElement("a");
          a.setAttribute("href", href);
          a.setAttribute("target", "_blank");
          a.setAttribute("rel", "noopener noreferrer");
          a.textContent = m[1];
          parent.appendChild(a);
          i += m[0].length; continue;
        }
      }
      buf += c; i++;
    }
    flush();
  }

  function lines(doc, parent, rows) {
    rows.forEach((row, k) => {
      if (k) parent.appendChild(doc.createElement("br"));
      inline(doc, parent, row);
    });
  }

  function render(doc, text) {
    const frag = doc.createDocumentFragment();
    try {
      const rows = String(text ?? "").replace(/\r\n?/g, "\n").split("\n");
      let para = [], list = null, listTag = "";
      const endPara = () => {
        if (!para.length) return;
        const p = doc.createElement("p");
        lines(doc, p, para);
        frag.appendChild(p);
        para = [];
      };
      const endList = () => { list = null; };
      for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        if (/^```/.test(row)) {
          let j = i + 1;
          while (j < rows.length && !/^```\s*$/.test(rows[j])) j++;
          if (j < rows.length) { // closed fence; an unclosed one stays literal text
            endPara(); endList();
            const pre = doc.createElement("pre");
            pre.textContent = rows.slice(i + 1, j).join("\n");
            frag.appendChild(pre);
            i = j; continue;
          }
        }
        if (!row.trim()) { endPara(); endList(); continue; }
        let m = /^(#{1,3}) +(\S.*)$/.exec(row);
        if (m) {
          endPara(); endList();
          const h = doc.createElement("h" + m[1].length);
          inline(doc, h, m[2]);
          frag.appendChild(h);
          continue;
        }
        m = /^(?:([-*])|(\d+)\.) +(\S.*)$/.exec(row);
        if (m) {
          endPara();
          const tag = m[1] ? "ul" : "ol";
          if (!list || listTag !== tag) {
            list = doc.createElement(tag); listTag = tag;
            frag.appendChild(list);
          }
          const li = doc.createElement("li");
          inline(doc, li, m[3]);
          list.appendChild(li);
          continue;
        }
        endList();
        para.push(row);
      }
      endPara();
    } catch {
      frag.textContent = String(text ?? ""); // never throw into the chat page
    }
    return frag;
  }

  globalThis.SCMarkdown = { render };
})();
