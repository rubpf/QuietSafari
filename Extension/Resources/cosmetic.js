// Hides well-known ad slots as soon as the document exists.
// Waiting for document_idle let the ad script itself delay this script, so the
// test page stayed red even when the extension was enabled.
// Network blocking is done by the content blocker, which cannot report hits.

const ext = globalThis.browser ?? globalThis.chrome;

const SELECTORS = [
  "ins.adsbygoogle",
  ".adsbygoogle",
  'iframe[src*="doubleclick.net"]',
  'iframe[src*="googlesyndication.com"]',
  'iframe[id^="google_ads_iframe"]',
  'div[id^="google_ads_iframe"]',
  'div[id^="div-gpt-ad"]',
  'div[id^="yandex_rtb"]',
  'div[class^="yandex_rtb"]',
  'div[id^="adfox_"]',
  ".yandex-rtb",
  ".yandex-rtb-block",
];

const STYLE_ID = "quiet-safari-cosmetic";

function hostAllowed(allowlist) {
  const host = location.hostname;
  return !allowlist.some((domain) => host === domain || host.endsWith("." + domain));
}

function installStyle() {
  const root = document.documentElement;
  if (!root) {
    return false;
  }
  root.dataset.qsCosmeticSeen = "1";
  if (!document.getElementById(STYLE_ID)) {
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = SELECTORS.join(",") + "{display:none!important}";
    root.appendChild(style);
  }
  return true;
}

function markNodes() {
  const seen = new Set();
  for (const selector of SELECTORS) {
    document.querySelectorAll(selector).forEach((node) => {
      if (node.querySelector("video") || node.closest("#movie_player")) {
        return;
      }
      node.dataset.qsBy = "extension";
      seen.add(node);
    });
  }
  return seen.size;
}

function removeStyle() {
  document.getElementById(STYLE_ID)?.remove();
  document.querySelectorAll("[data-qs-by='extension']").forEach((node) => {
    delete node.dataset.qsBy;
  });
}

function boot() {
  if (!installStyle()) {
    document.addEventListener("DOMContentLoaded", boot, { once: true });
    return;
  }
  let reported = markNodes();
  const root = document.documentElement;
  const observer = new MutationObserver(() => {
    const extra = markNodes();
    if (extra > reported) {
      ext.runtime.sendMessage({ type: "addBlocked", count: extra - reported }).catch(() => {});
      reported = extra;
    }
  });
  observer.observe(root, { childList: true, subtree: true });
  setTimeout(() => observer.disconnect(), 20000);
  if (reported > 0) {
    ext.runtime.sendMessage({ type: "addBlocked", count: reported }).catch(() => {});
  }
  ext.runtime
    .sendMessage({ type: "getState" })
    .then((state) => {
      if (!state || state.blockingEnabled === false) {
        removeStyle();
        return;
      }
      if (Array.isArray(state.allowlist) && !hostAllowed(state.allowlist)) {
        root.dataset.qsAllowlisted = "1";
        removeStyle();
      }
    })
    .catch(() => {
      // Keep the slots hidden if the app does not answer.
    });
}

boot();
