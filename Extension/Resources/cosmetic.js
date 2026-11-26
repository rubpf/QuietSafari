// Hides a few well-known ad slots and counts them once per page.
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

function hostAllowed(allowlist) {
  const host = location.hostname;
  return !allowlist.some((domain) => host === domain || host.endsWith("." + domain));
}

function hideAndCount() {
  const seen = new Set();
  for (const selector of SELECTORS) {
    document.querySelectorAll(selector).forEach((node) => {
      if (node.querySelector("video")) {
        return;
      }
      seen.add(node);
      node.style.setProperty("display", "none", "important");
    });
  }
  return seen.size;
}

async function main() {
  let allowed = true;
  try {
    const state = await ext.runtime.sendMessage({ type: "getState" });
    if (state && state.blockingEnabled === false) {
      allowed = false;
    } else if (state && Array.isArray(state.allowlist)) {
      allowed = hostAllowed(state.allowlist);
    }
  } catch (error) {
    allowed = true;
  }
  if (!allowed || !document.documentElement || document.documentElement.dataset.qsCosmetic === "1") {
    return;
  }
  document.documentElement.dataset.qsCosmetic = "1";
  let reported = hideAndCount();
  if (reported > 0) {
    ext.runtime.sendMessage({ type: "addBlocked", count: reported });
  }
  const root = document.documentElement;
  if (!root) {
    return;
  }
  const observer = new MutationObserver(() => {
    const extra = hideAndCount();
    if (extra > reported) {
      ext.runtime.sendMessage({ type: "addBlocked", count: extra - reported });
      reported = extra;
    }
  });
  observer.observe(root, { childList: true, subtree: true });
  setTimeout(() => observer.disconnect(), 20000);
}

main();
