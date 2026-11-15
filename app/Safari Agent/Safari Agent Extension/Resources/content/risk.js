(() => {
  const SC = (globalThis.SC ??= {});
  if (SC.classifyRisk) return;

  const PAYMENT = /оплат|купить|заказать|pay|buy|purchase|checkout|order/i;
  const SEND = /отправить|send|опубликовать|publish|post/i;
  const DELETE = /удалить|delete|remove|стереть/i;
  const CARD_NAME = /card|cvv|cvc|iban/i;

  const textsOf = (el) =>
    [el.textContent, el.value, el.getAttribute?.("aria-label"), el.getAttribute?.("title")]
      .filter((s) => typeof s === "string")
      .join(" ")
      .toLowerCase();

  function formIsPayment(form) {
    if (!form) return false;
    if (form.querySelector("input[type=password], [autocomplete^=cc-]")) return true;
    return [...form.querySelectorAll("[name], [id]")].some((e) => CARD_NAME.test(e.getAttribute("name") ?? "") || CARD_NAME.test(e.id ?? ""));
  }

  SC.classifyRisk = (el) => {
    const form = el.closest?.("form") ?? el.form ?? null;
    if (formIsPayment(form)) return { risky: true, kind: "payment" };
    const t = textsOf(el);
    if (PAYMENT.test(t)) return { risky: true, kind: "payment" };
    if (SEND.test(t)) return { risky: true, kind: "send" };
    if (DELETE.test(t)) return { risky: true, kind: "delete" };
    if (form && el.type === "submit" && form.querySelector("input[type=password]")) return { risky: true, kind: "submit" };
    return { risky: false };
  };

  SC.formIsPayment = formIsPayment;
})();
