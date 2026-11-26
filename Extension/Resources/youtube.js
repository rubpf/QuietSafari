// YouTube-only behavior. Keep every YouTube DOM dependency in this file.
//
// When YouTube changes its markup, update SELECTORS and skipVideoAd.
// Do not block googlevideo.com or youtube.com: that stops the real video.
//
// Order of attempts:
// 1. Hide in-feed promos and banners (not the <video> element).
// 2. Click YouTube's skip button when it is on screen.
// 3. If the player says an ad is showing and that ad is shorter than three
//    minutes, jump to the end of it. Longer media is left alone so a normal
//    video is not skipped when the player class is wrong.

const ext = globalThis.browser ?? globalThis.chrome;

const SELECTORS = {
  slots: [
    "ytd-ad-slot-renderer",
    "ytd-banner-promo-renderer",
    "ytd-video-masthead-ad-advertiser-info-renderer",
    "ytd-video-masthead-ad-v3-renderer",
    "ytd-primetime-promo-renderer",
    "ytd-in-feed-ad-layout-renderer",
    "ytd-statement-banner-renderer",
    "ytd-brand-video-singleton-renderer",
    "ytd-display-ad-renderer",
    "ytd-promoted-sparkles-web-renderer",
    "ytd-promoted-sparkles-text-search-renderer",
    "ytd-companion-slot-renderer",
    "ytd-action-companion-ad-renderer",
    "#player-ads",
    "#masthead-ad",
    ".ytp-ad-overlay-container",
    ".ytp-ad-text-overlay",
    ".ytp-ad-image-overlay",
  ],
  skipButtons: [
    ".ytp-skip-ad-button",
    ".ytp-ad-skip-button",
    ".ytp-ad-skip-button-modern",
    ".ytp-ad-skip-button-slot button",
    ".ytp-skip-ad-button__text",
  ],
};

const MAX_AD_SECONDS = 180;

let cache = { at: 0, allowed: true };
let timer = null;

async function blockingAllowed() {
  const now = Date.now();
  if (now - cache.at < 5000) {
    return cache.allowed;
  }
  try {
    const state = await ext.runtime.sendMessage({ type: "getState" });
    const host = location.hostname;
    const list = state && Array.isArray(state.allowlist) ? state.allowlist : [];
    const enabled = !state || state.blockingEnabled !== false;
    const listed = list.some((domain) => host === domain || host.endsWith("." + domain));
    cache = { at: now, allowed: enabled && !listed };
  } catch (error) {
    cache = { at: now, allowed: true };
  }
  return cache.allowed;
}

function installStyle() {
  if (document.getElementById("quiet-safari-style")) {
    return;
  }
  const style = document.createElement("style");
  style.id = "quiet-safari-style";
  style.textContent = SELECTORS.slots.join(",") + "{display:none!important}";
  (document.documentElement || document.head).appendChild(style);
}

function hideSlots() {
  let count = 0;
  for (const selector of SELECTORS.slots) {
    document.querySelectorAll(selector).forEach((node) => {
      if (node.dataset.qsHidden === "1" || node.id === "movie_player" || node.closest("#movie_player")) {
        return;
      }
      node.dataset.qsHidden = "1";
      node.style.setProperty("display", "none", "important");
      count += 1;
    });
  }
  return count;
}

function playerIsShowingAd(player) {
  if (player.classList.contains("ad-showing") || player.classList.contains("ad-interrupting")) {
    return true;
  }
  if (player.querySelector(".ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button")) {
    return true;
  }
  const overlay = player.querySelector(".ytp-ad-player-overlay");
  return Boolean(overlay && overlay.offsetParent !== null);
}

function skipVideoAd() {
  const player = document.querySelector("#movie_player, .html5-video-player");
  if (!player || !playerIsShowingAd(player)) {
    if (player) {
      delete player.dataset.qsAdHandled;
    }
    return 0;
  }
  if (player.dataset.qsAdHandled === "1") {
    return 0;
  }

  const buttons = player.querySelectorAll("button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button");
  for (const button of buttons) {
    const text = (button.innerText || "").trim().toLowerCase();
    const className = String(button.className || "");
    const looksLikeSkip = className.includes("skip") || text === "skip" || text.startsWith("skip ") || text.includes("пропустить");
    if (looksLikeSkip) {
      button.click();
    }
  }
  for (const selector of SELECTORS.skipButtons) {
    const button = player.querySelector(selector);
    if (button && typeof button.click === "function") {
      button.click();
    }
  }

  const video = player.querySelector("video");
  const duration = video ? video.duration : NaN;
  if (!video || !Number.isFinite(duration) || duration <= 0.3 || duration > MAX_AD_SECONDS) {
    return 0;
  }
  if (video.currentTime < duration - 0.2) {
    video.currentTime = Math.max(0, duration - 0.05);
    player.dataset.qsAdHandled = "1";
    return 1;
  }
  return 0;
}

async function tick() {
  if (!(await blockingAllowed())) {
    return;
  }
  const count = hideSlots() + skipVideoAd();
  if (count > 0) {
    ext.runtime.sendMessage({ type: "addBlocked", count });
  }
}

function schedule() {
  if (timer !== null) {
    return;
  }
  timer = setTimeout(() => {
    timer = null;
    tick();
  }, 300);
}

function injectMainBackup() {
  try {
    if (window.__quietSafariYouTube) {
      return;
    }
    const script = document.createElement("script");
    script.src = ext.runtime.getURL("youtube-main.js");
    script.async = false;
    (document.documentElement || document.head).appendChild(script);
  } catch (error) {
    // The manifest MAIN-world script is the one that has to win the race.
  }
}

function start() {
  const root = document.documentElement;
  if (!root) {
    document.addEventListener("DOMContentLoaded", start, { once: true });
    return;
  }
  installStyle();
  injectMainBackup();
  const observer = new MutationObserver(schedule);
  observer.observe(root, { childList: true, subtree: true });
  schedule();
}

start();
