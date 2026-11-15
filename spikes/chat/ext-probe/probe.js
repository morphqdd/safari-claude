document.getElementById("i").textContent = innerWidth + "x" + innerHeight;
const port = (globalThis.browser ?? chrome).runtime.connect({ name: "chat" });
port.postMessage({ hello: location.href });
