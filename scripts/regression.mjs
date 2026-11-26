// Counts visible ad slots in headless Chrome.
// Safari's content blocker is not running here. The script checks the same
// cosmetic selectors, the scriptlet engine, and (best effort) rifme.net after
// the Yandex container style is injected.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const engineSource = await readFile(join(root, "Extension/Resources/engine.js"), "utf8");
const cosmeticSource = await readFile(join(root, "Extension/Resources/cosmetic.js"), "utf8");

const fixture = `<!doctype html>
<html>
<body>
  <p id="keep">Этот блок должен быть виден</p>
  <div id="yandex_rtb_R-A-1"><span class="label">РЕКЛАМА</span> карточка</div>
  <ins class="adsbygoogle">ad</ins>
  <div id="wrap"><div class="ad-card">sponsored card</div></div>
  <div id="onetrust-banner-sdk">cookie</div>
  <script>
    globalThis.QUIETSAFARI_ENGINE_RULES = {
      scriptlets: [{ domains: ["127.0.0.1"], name: "set-constant", args: ["canRunAds", "false"] }],
      procedural: [{ domains: ["127.0.0.1"], kind: "css", selector: "div:-abp-has(> .ad-card)" }]
    };
  </script>
  <script>${engineSource}</script>
  <script>${cosmeticSource.replace("const ext = globalThis.browser ?? globalThis.chrome;", "const ext = { runtime: { sendMessage() { return Promise.resolve({ blockingEnabled: true, allowlist: [] }); } } };")}</script>
</body>
</html>`;

function visible(id) {
  const node = document.querySelector(id);
  if (!node) return false;
  const style = getComputedStyle(node);
  return style.display !== "none" && style.visibility !== "hidden" && node.getClientRects().length > 0;
}

const countExpression = `(() => {
  const ads = ["#yandex_rtb_R-A-1", "ins.adsbygoogle", "#wrap"].filter((sel) => (${visible.toString()})(sel));
  return {
    visibleAds: ads.length,
    keep: (${visible.toString()})("#keep"),
    cookie: (${visible.toString()})("#onetrust-banner-sdk"),
    canRunAds: window.canRunAds,
  };
})()`;

const rifmeExpression = `(() => {
  const nodes = Array.from(document.querySelectorAll('[id^="yandex_rtb"], .yandex-rtb'));
  const shown = nodes.filter((node) => {
    const style = getComputedStyle(node);
    return style.display !== "none" && node.getClientRects().length > 0;
  });
  return { containers: nodes.length, visible: shown.length };
})()`;

class Browser {
  constructor(port, child, dir) {
    this.port = port;
    this.child = child;
    this.dir = dir;
    this.id = 0;
    this.pending = new Map();
  }

  async ready() {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      try {
        const response = await fetch(`http://127.0.0.1:${this.port}/json/version`);
        if (response.ok) return;
      } catch (error) {
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
    }
    throw new Error("Chrome did not open a debugging port");
  }

  async connect(url) {
    const created = await fetch(`http://127.0.0.1:${this.port}/json/new?${encodeURIComponent(url)}`, { method: "PUT" });
    if (!created.ok) {
      throw new Error(`could not open ${url}: ${created.status}`);
    }
    const page = await created.json();
    this.ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", () => reject(new Error("debugger socket failed")), { once: true });
    });
    this.ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
      }
    });
    await this.send("Page.enable");
    await this.send("Runtime.enable");
    return page.id;
  }

  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const result = await this.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) {
      throw new Error(JSON.stringify(result.exceptionDetails));
    }
    return result.result.value;
  }

  async stop() {
    this.child.kill();
    await new Promise((resolve) => setTimeout(resolve, 400));
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        await rm(this.dir, { recursive: true, force: true });
        return;
      } catch (error) {
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
    }
  }
}

async function launch() {
  const dir = await mkdtemp(join(tmpdir(), "qs-regression-"));
  const port = 9333 + Math.floor(Math.random() * 400);
  const child = spawn(
    "google-chrome",
    [
      "--headless=new",
      "--disable-gpu",
      "--no-sandbox",
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${dir}`,
      "about:blank",
    ],
    { stdio: "ignore" }
  );
  const browser = new Browser(port, child, dir);
  await browser.ready();
  return browser;
}

const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  response.end(fixture);
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const fixtureURL = `http://127.0.0.1:${server.address().port}/`;
const browser = await launch();
const failures = [];

try {
  await browser.connect(fixtureURL);
  await new Promise((resolve) => setTimeout(resolve, 500));
  const local = await browser.evaluate(countExpression);
  if (local.visibleAds !== 0) failures.push(`fixture still shows ${local.visibleAds} ad slots`);
  if (!local.keep) failures.push("fixture hid the paragraph that must stay");
  if (!local.cookie) failures.push("cookie banner was hidden while the toggle is off");
  if (local.canRunAds !== false) failures.push(`set-constant did not set canRunAds, got ${local.canRunAds}`);

  try {
    await browser.connect("https://rifme.net/");
    await new Promise((resolve) => setTimeout(resolve, 4000));
    const before = await browser.evaluate(rifmeExpression);
    await browser.evaluate(`(() => {
      const style = document.createElement("style");
      style.textContent = 'div[id^="yandex_rtb"], .yandex-rtb, div[id^="adfox_"]{display:none!important}';
      document.documentElement.appendChild(style);
    })()`);
    await new Promise((resolve) => setTimeout(resolve, 300));
    const after = await browser.evaluate(rifmeExpression);
    console.log("rifme.net", { before, after });
    if (before.containers === 0) {
      console.log("rifme.net had no yandex_rtb containers in this load; the selector check is skipped");
    } else if (after.visible !== 0) {
      failures.push(`rifme.net still shows ${after.visible} Yandex containers after the style`);
    }
  } catch (error) {
    console.log("rifme.net was not reachable:", error.message);
  }
} finally {
  await browser.stop();
  server.close();
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("regression ok");
