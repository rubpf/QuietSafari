// Optional cookie-banner hiding. Off unless the settings window enables it.
// The selectors are QuietSafari's own, not a third-party annoyance list.

const ext = globalThis.browser ?? globalThis.chrome;

const COOKIE_SELECTORS = [
  "#onetrust-banner-sdk",
  "#onetrust-consent-sdk",
  "#CybotCookiebotDialog",
  "#cookie-law-info-bar",
  "#cookieConsent",
  ".cookie-notice",
  ".cc-window",
  ".fc-consent-root",
].join(",");

function installCookieStyle() {
  if (document.getElementById("quiet-safari-cookies")) {
    return;
  }
  const style = document.createElement("style");
  style.id = "quiet-safari-cookies";
  style.textContent = COOKIE_SELECTORS + "{display:none!important}";
  (document.documentElement || document.head).appendChild(style);
}

async function main() {
  let enabled = false;
  try {
    const state = await ext.runtime.sendMessage({ type: "getState" });
    enabled = Boolean(state && state.blockCookieNotices && state.blockingEnabled !== false);
  } catch (error) {
    enabled = false;
  }
  if (!enabled) {
    return;
  }
  installCookieStyle();
  const root = document.documentElement;
  if (!root) {
    return;
  }
  const observer = new MutationObserver(() => installCookieStyle());
  observer.observe(root, { childList: true, subtree: true });
  setTimeout(() => observer.disconnect(), 15000);
}

main();
