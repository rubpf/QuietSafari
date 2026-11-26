// Page-world engine for a small, named set of scriptlets and procedural cosmetics.
// Filter lists only select these scriptlets. Arbitrary page script is never executed.
// Rules without a domain are ignored, except a few Yandex container selectors.

(function () {
  if (window.__quietSafariEngine) {
    return;
  }
  window.__quietSafariEngine = true;

  var bundle = window.QUIETSAFARI_ENGINE_RULES || { scriptlets: [], procedural: [] };
  var host = (location.hostname || "").toLowerCase();

  function domainMatches(domains) {
    if (!domains || !domains.length) {
      return false;
    }
    for (var i = 0; i < domains.length; i += 1) {
      var domain = String(domains[i] || "").toLowerCase();
      if (!domain) {
        continue;
      }
      if (host === domain || host.endsWith("." + domain)) {
        return true;
      }
    }
    return false;
  }

  function parseConstant(raw) {
    var text = String(raw == null ? "" : raw).trim();
    var lower = text.toLowerCase();
    if (lower === "false" || lower === "no" || lower === "0") return false;
    if (lower === "true" || lower === "yes" || lower === "1") return true;
    if (lower === "undefined" || lower === "noop" || text === "") return undefined;
    if (lower === "null") return null;
    if (lower === "emptyarray" || text === "[]") return [];
    if (lower === "emptyobject" || text === "{}") return {};
    if (/^-?\d+(\.\d+)?$/.test(text)) return Number(text);
    return text;
  }

  function assignPath(root, path, value, trap) {
    var parts = String(path).split(".").filter(Boolean);
    if (!parts.length) return;
    var leaf = parts[parts.length - 1];
    if (leaf.length < 4) return;
    var object = root;
    for (var i = 0; i < parts.length - 1; i += 1) {
      if (!object) return;
      object = object[parts[i]];
    }
    if (!object) return;
    try {
      Object.defineProperty(object, leaf, {
        configurable: true,
        get: function () {
          if (trap === "read") {
            throw new ReferenceError(leaf);
          }
          return value;
        },
        set: function () {
          if (trap === "write") {
            throw new ReferenceError(leaf);
          }
        },
      });
    } catch (error) {
      // The page already locked the property. Leave the site alone.
    }
  }

  function applyScriptlet(rule) {
    if (!domainMatches(rule.domains)) return;
    var name = rule.name;
    var args = rule.args || [];
    if (name === "set-constant") {
      assignPath(window, args[0] || "", parseConstant(args[1]), "value");
      return;
    }
    if (name === "abort-on-property-read") {
      assignPath(window, args[0] || "", undefined, "read");
      return;
    }
    if (name === "abort-on-property-write") {
      assignPath(window, args[0] || "", undefined, "write");
      return;
    }
    if (name === "json-prune") {
      window.__qsPruneKeys = (window.__qsPruneKeys || []).concat(args);
      return;
    }
    if (name === "prevent-fetch") {
      window.__qsFetchNeedles = (window.__qsFetchNeedles || []).concat(args);
      return;
    }
    if (name === "prevent-xhr") {
      window.__qsXhrNeedles = (window.__qsXhrNeedles || []).concat(args);
      return;
    }
    if (name === "remove-node-text") {
      var needle = args[args.length - 1] || "";
      var selector = args.length > 1 ? args[0] : "div,aside,section";
      if (needle.length >= 6 && selector !== "body" && selector !== "html" && selector !== "*") {
        window.__qsRemoveText = (window.__qsRemoveText || []).concat([{ selector: selector, needle: needle }]);
      }
    }
  }

  (bundle.scriptlets || []).forEach(applyScriptlet);

  function pruneKeys(value, keys, depth) {
    if (!value || typeof value !== "object" || depth > 12) return value;
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i += 1) pruneKeys(value[i], keys, depth + 1);
      return value;
    }
    Object.keys(value).forEach(function (key) {
      if (keys.indexOf(key) !== -1) {
        delete value[key];
      } else {
        pruneKeys(value[key], keys, depth + 1);
      }
    });
    return value;
  }

  var pruneList = window.__qsPruneKeys || [];
  if (pruneList.length && !window.__qsParseHook) {
    window.__qsParseHook = true;
    var nativeParse = JSON.parse;
    JSON.parse = function (text, reviver) {
      var value = nativeParse.call(this, text, reviver);
      try {
        if (typeof text === "string" && text.length > 200) {
          pruneKeys(value, pruneList, 0);
        }
      } catch (error) {
        return value;
      }
      return value;
    };
  }

  function blockedURL(url, needles) {
    var text = String(url || "");
    for (var i = 0; i < needles.length; i += 1) {
      if (text.indexOf(needles[i]) !== -1) return true;
    }
    return false;
  }

  var fetchNeedles = window.__qsFetchNeedles || [];
  if (fetchNeedles.length && typeof window.fetch === "function" && !window.__qsFetchHook) {
    window.__qsFetchHook = true;
    var nativeFetch = window.fetch;
    window.fetch = function (input) {
      try {
        var url = typeof input === "string" ? input : input && input.url;
        if (blockedURL(url, fetchNeedles)) {
          return Promise.resolve(new Response("", { status: 200 }));
        }
      } catch (error) {
        // Fall through to the real fetch.
      }
      return nativeFetch.apply(this, arguments);
    };
  }

  var xhrNeedles = window.__qsXhrNeedles || [];
  if (xhrNeedles.length && window.XMLHttpRequest && !window.__qsXhrHook) {
    window.__qsXhrHook = true;
    var nativeOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        if (blockedURL(url, xhrNeedles)) {
          this.__qsBlocked = true;
        }
      } catch (error) {
        this.__qsBlocked = false;
      }
      return nativeOpen.apply(this, arguments);
    };
    var nativeSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function () {
      if (this.__qsBlocked) {
        return;
      }
      return nativeSend.apply(this, arguments);
    };
  }

  function cssFromProcedural(selector) {
    return selector.replace(/:-abp-has\(/gi, ":has(");
  }

  function collectCSS() {
    var css = [];
    (bundle.procedural || []).forEach(function (rule) {
      if (rule.kind !== "css") return;
      if (rule.domains && rule.domains.length && !domainMatches(rule.domains)) return;
      var selector = cssFromProcedural(rule.selector || "");
      if (selector.indexOf(":has-text") !== -1 || selector.indexOf(":upward") !== -1) return;
      if (selector.indexOf(":has(") === -1) return;
      css.push(selector + "{display:none!important}");
    });
    return css.slice(0, 400).join("\n");
  }

  function textRules() {
    return (bundle.procedural || []).filter(function (rule) {
      if (rule.kind !== "text" && rule.kind !== "upward") return false;
      if (rule.domains && rule.domains.length && !domainMatches(rule.domains)) return false;
      return true;
    }).slice(0, 80);
  }

  function needleOf(selector) {
    var match = String(selector).match(/:(?:-abp-)?(?:has-text|contains)\(([^)]+)\)/i);
    return match ? match[1].replace(/^['"]|['"]$/g, "") : "";
  }

  function hideTextual(rules) {
    var hidden = 0;
    rules.forEach(function (rule) {
      var needle = needleOf(rule.selector);
      if (needle.length < 6) return;
      var nodes = document.querySelectorAll("div,aside,section,li,p");
      var seen = 0;
      for (var i = 0; i < nodes.length && seen < 30; i += 1) {
        var node = nodes[i];
        if (node.closest && node.closest("#movie_player")) continue;
        var own = (node.innerText || "").trim();
        if (own.length > 400 || own.indexOf(needle) === -1) continue;
        var target = node;
        if (rule.kind === "upward" && node.parentElement && node.parentElement !== document.body) {
          target = node.parentElement;
        }
        if (target === document.body || target === document.documentElement) continue;
        target.style.setProperty("display", "none", "important");
        hidden += 1;
        seen += 1;
      }
    });
    return hidden;
  }

  function install() {
    var css = collectCSS();
    if (css && !document.getElementById("quiet-safari-procedural")) {
      var style = document.createElement("style");
      style.id = "quiet-safari-procedural";
      style.textContent = css;
      (document.documentElement || document.head).appendChild(style);
    }
    var rules = textRules();
    var textJobs = window.__qsRemoveText || [];
    if (!rules.length && !textJobs.length && !css) return;
    function hideListedText() {
      textJobs.forEach(function (job) {
        var nodes;
        try {
          nodes = document.querySelectorAll(job.selector);
        } catch (error) {
          return;
        }
        var seen = 0;
        for (var i = 0; i < nodes.length && seen < 20; i += 1) {
          var node = nodes[i];
          if (!node || node === document.body || (node.closest && node.closest("#movie_player"))) continue;
          var own = (node.innerText || "").trim();
          if (own.length > 400 || own.indexOf(job.needle) === -1) continue;
          node.style.setProperty("display", "none", "important");
          seen += 1;
        }
      });
    }
    var run = function () {
      hideListedText();
      hideTextual(rules);
    };
    run();
    var root = document.documentElement;
    if (!root || window.__qsProceduralObserver) return;
    var timer = null;
    window.__qsProceduralObserver = new MutationObserver(function () {
      if (timer) return;
      timer = setTimeout(function () {
        timer = null;
        run();
      }, 400);
    });
    window.__qsProceduralObserver.observe(root, { childList: true, subtree: true });
    setTimeout(function () {
      if (window.__qsProceduralObserver) {
        window.__qsProceduralObserver.disconnect();
      }
    }, 20000);
  }

  if (document.documentElement) {
    install();
  } else {
    document.addEventListener("DOMContentLoaded", install, { once: true });
  }
})();
