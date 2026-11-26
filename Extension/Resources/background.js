// Relays page reports to the macOS app and caches the switch / allowlist.

const ext = globalThis.browser ?? globalThis.chrome;
const NATIVE_APP = "com.quietsafari.macos";

function readLocal() {
  return ext.storage.local.get({
    blockingEnabled: true,
    allowlist: [],
    blockedCount: 0,
    blockCookieNotices: false,
  });
}

async function syncFromApp() {
  const local = await readLocal();
  try {
    const response = await ext.runtime.sendNativeMessage(NATIVE_APP, { type: "getState" });
    if (!response || response.ok === false) {
      return local;
    }
    const remoteCount = Number(response.blockedCount) || 0;
    const localCount = Number(local.blockedCount) || 0;
    const next = {
      blockingEnabled: response.blockingEnabled !== false,
      allowlist: Array.isArray(response.allowlist) ? response.allowlist : [],
      blockCookieNotices: response.blockCookieNotices === true,
      blockedCount: Math.max(localCount, remoteCount),
    };
    await ext.storage.local.set(next);
    if (next.blockedCount !== remoteCount) {
      try {
        await ext.runtime.sendNativeMessage(NATIVE_APP, {
          type: "setBlockedCount",
          blockedCount: next.blockedCount,
        });
      } catch (error) {
        // The popup still shows the number stored in the extension.
      }
    }
    return next;
  } catch (error) {
    return local;
  }
}

ext.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message.type !== "string") {
    return undefined;
  }

  if (message.type === "getState") {
    syncFromApp()
      .then((state) => sendResponse(state))
      .catch(() => sendResponse({ blockingEnabled: true, allowlist: [], blockedCount: 0 }));
    return true;
  }

  if (message.type === "addBlocked") {
    const delta = Math.max(0, Number(message.count) || 0);
    readLocal()
      .then(async (local) => {
        if (local.blockingEnabled === false || delta === 0) {
          sendResponse({ ok: true, blockedCount: Number(local.blockedCount) || 0 });
          return;
        }
        const blockedCount = (Number(local.blockedCount) || 0) + delta;
        await ext.storage.local.set({ blockedCount });
        try {
          await ext.runtime.sendNativeMessage(NATIVE_APP, {
            type: "setBlockedCount",
            blockedCount,
          });
        } catch (error) {
          // Counting in the toolbar still works without the shared folder.
        }
        sendResponse({ ok: true, blockedCount });
      })
      .catch(() => sendResponse({ ok: false }));
    return true;
  }

  return undefined;
});

function scheduleSync() {
  if (!ext.alarms) {
    return;
  }
  ext.alarms.create("sync-state", { periodInMinutes: 1 });
  ext.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === "sync-state") {
      syncFromApp();
    }
  });
}

if (ext.runtime.onInstalled) {
  ext.runtime.onInstalled.addListener(() => {
    syncFromApp();
  });
}

scheduleSync();
syncFromApp();
