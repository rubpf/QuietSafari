const ext = globalThis.browser ?? globalThis.chrome;

function show(state) {
  const status = document.getElementById("status");
  const count = document.getElementById("count");
  const enabled = !state || state.blockingEnabled !== false;
  status.textContent = enabled ? "Blocking is on." : "Blocking is off.";
  const total = Number(state && state.blockedCount) || 0;
  count.textContent = "Seen: " + total + (total === 1 ? " item." : " items.");
}

ext.runtime
  .sendMessage({ type: "getState" })
  .then(show)
  .catch(() => show({ blockingEnabled: true, blockedCount: 0 }));
