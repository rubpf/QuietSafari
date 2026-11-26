// Page-world YouTube handler. Runs at document_start before the player's scripts.
// It only removes known ad fields and ad renderers. videoDetails and streamingData
// stay untouched, and any error falls back to the original value so playback continues.
// This file cannot use extension APIs: Safari runs it in the page world.

(function () {
  if (window.__quietSafariYouTube) {
    return;
  }
  window.__quietSafariYouTube = true;

  var PRUNE_KEYS = {
    adPlacements: true,
    playerAds: true,
    adSlots: true,
    adBreakHeartbeatParams: true,
  };

  var AD_RENDERERS = {
    adSlotRenderer: true,
    videoMastheadAdRenderer: true,
    videoMastheadAdV3Renderer: true,
    primetimePromoRenderer: true,
    promotedSparklesTextSearchRenderer: true,
    promotedSparklesWebRenderer: true,
    inFeedAdLayoutRenderer: true,
    bannerPromoRenderer: true,
    statementBannerRenderer: true,
    brandVideoSingletonRenderer: true,
    displayAdRenderer: true,
    actionCompanionAdRenderer: true,
    compactPromotedVideoRenderer: true,
    promotedVideoRenderer: true,
    playerLegacyDesktopWatchAdsRenderer: true,
  };

  function isAdNode(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }
    var keys = Object.keys(value);
    for (var i = 0; i < keys.length; i += 1) {
      if (AD_RENDERERS[keys[i]]) {
        return true;
      }
    }
    return false;
  }

  function prune(value, depth) {
    if (!value || typeof value !== "object" || depth > 40) {
      return value;
    }
    if (Array.isArray(value)) {
      var next = [];
      for (var i = 0; i < value.length; i += 1) {
        if (isAdNode(value[i])) {
          continue;
        }
        next.push(prune(value[i], depth + 1));
      }
      return next;
    }
    var copy = {};
    var keys = Object.keys(value);
    for (var j = 0; j < keys.length; j += 1) {
      var key = keys[j];
      if (PRUNE_KEYS[key]) {
        continue;
      }
      copy[key] = prune(value[key], depth + 1);
    }
    return copy;
  }

  function pruneValue(value) {
    try {
      return prune(value, 0);
    } catch (error) {
      return value;
    }
  }

  function textHasAds(text) {
    return (
      text.indexOf("adPlacements") !== -1 ||
      text.indexOf("playerAds") !== -1 ||
      text.indexOf("adSlots") !== -1 ||
      text.indexOf("adSlotRenderer") !== -1 ||
      text.indexOf("videoMastheadAd") !== -1 ||
      text.indexOf('"adBreakHeartbeatParams"') !== -1
    );
  }

  function installProperty(name) {
    var current;
    try {
      current = window[name];
    } catch (error) {
      current = undefined;
    }
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        enumerable: true,
        get: function () {
          return current;
        },
        set: function (value) {
          current = pruneValue(value);
        },
      });
    } catch (error) {
      return;
    }
    if (current) {
      current = pruneValue(current);
    }
  }

  installProperty("ytInitialPlayerResponse");
  installProperty("ytInitialData");

  var nativeParse = JSON.parse;
  JSON.parse = function (text, reviver) {
    var value = nativeParse.call(this, text, reviver);
    try {
      if (typeof text === "string" && text.length > 400 && textHasAds(text)) {
        return pruneValue(value);
      }
    } catch (error) {
      return value;
    }
    return value;
  };
  try {
    JSON.parse.toString = function () {
      return nativeParse.toString();
    };
  } catch (error) {
    // Leaving parse visible is still safe.
  }

  var nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    window.fetch = function () {
      return nativeFetch.apply(this, arguments).then(function (response) {
        try {
          var url = String((response && response.url) || "");
          if (!/\/youtubei\/v1\/(player|browse|next|search|reel)/.test(url)) {
            return response;
          }
          return response
            .clone()
            .text()
            .then(function (text) {
              if (!textHasAds(text)) {
                return response;
              }
              var parsed = nativeParse(text);
              var body = JSON.stringify(pruneValue(parsed));
              return new Response(body, {
                status: response.status,
                statusText: response.statusText,
                headers: response.headers,
              });
            })
            .catch(function () {
              return response;
            });
        } catch (error) {
          return response;
        }
      });
    };
    try {
      window.fetch.toString = function () {
        return nativeFetch.toString();
      };
    } catch (error) {
      // Same as JSON.parse: playback does not depend on hiding the hook.
    }
  }
})();
