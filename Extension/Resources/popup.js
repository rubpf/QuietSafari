const ext = globalThis.browser ?? globalThis.chrome;

function elementWord(count) {
  const value = Math.abs(count) % 100;
  const last = value % 10;
  if (value > 10 && value < 20) {
    return "элементов";
  }
  if (last === 1) {
    return "элемент";
  }
  if (last >= 2 && last <= 4) {
    return "элемента";
  }
  return "элементов";
}

function show(state) {
  const status = document.getElementById("status");
  const count = document.getElementById("count");
  const enabled = !state || state.blockingEnabled !== false;
  status.textContent = enabled ? "Блокировка включена." : "Блокировка выключена.";
  const total = Number(state && state.blockedCount) || 0;
  count.textContent = "Отмечено: " + total + " " + elementWord(total) + ".";
}

ext.runtime
  .sendMessage({ type: "getState" })
  .then(show)
  .catch(() => show({ blockingEnabled: true, blockedCount: 0 }));
