#!/usr/bin/env python3
"""Convert EasyList and EasyPrivacy into Safari content-blocker JSON.

The Swift converter in App/FilterConverter.swift is the same algorithm.
Keep the two in sync. This script also writes the lists shipped in the app.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path("/tmp/qs-filters")
ADS_OUT = ROOT / "Shared" / "blockerList.json"
PRIVACY_OUT = ROOT / "Shared" / "privacyList.json"
RUSSIAN_OUT = ROOT / "Shared" / "russianList.json"
ENGINE_RULES_OUT = ROOT / "Extension" / "Resources" / "engine-rules.js"

EASYLIST_URL = "https://easylist.to/easylist/easylist.txt"
EASYPRIVACY_URL = "https://easylist.to/easylist/easyprivacy.txt"
# RU AdList. License: CC BY 3.0 (see the file header).
RU_ADLIST_URL = "https://easylist-downloads.adblockplus.org/advblock.txt"

MAX_RULES = 140_000
MAX_BYTES = 7_200_000
MAX_SCRIPTLETS = 800
MAX_PROCEDURAL = 500

RESOURCE_TYPES = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "font": "font",
    "media": "media",
    "xmlhttprequest": "raw",
    "popup": "popup",
    "document": "document",
}
LOAD_TYPES = {
    "third-party": "third-party",
    "3p": "third-party",
    "first-party": "first-party",
    "1p": "first-party",
}
# subdocument/frame block the URL for every resource type, which is what we want
# for an ad iframe address. Negated type options are handled separately.
BARE_OPTIONS = {"subdocument", "frame", "important"}
ALL_TYPES = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]

# A block rule that matches any of these would stop real pages or video playback.
PROTECTED_URLS = [
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "https://www.youtube.com/",
    "https://youtube.com/",
    "https://rr1---sn-xxxx.googlevideo.com/videoplayback?id=1",
    "https://i.ytimg.com/vi/abcdef/hqdefault.jpg",
    "https://www.google.com/",
    "https://fonts.googleapis.com/css?family=Inter",
    "https://www.gstatic.com/images/branding.png",
    "https://yandex.ru/",
    "https://ya.ru/",
    "https://yandex.ru/search/?text=quiet",
    "https://yandex.ru/maps/213/moscow/",
    "https://yandex.com/maps/",
    "https://yastatic.net/s3/home-static/logo.png",
]

UNSAFE_SELECTOR = re.compile(
    r":has\(|:has-text|:xpath|:matches-css|:upward|:remove\(|:style\(|:-abp|\\|\{|\}|/|>>",
    re.IGNORECASE,
)


def download(url: str, name: str) -> str:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / name
    if not path.exists() or path.stat().st_size < 1000:
        request = urllib.request.Request(url, headers={"User-Agent": "QuietSafari/0.2"})
        path.write_bytes(urllib.request.urlopen(request, timeout=60).read())
    return path.read_text(encoding="utf-8", errors="replace")


def abp_to_regex(pattern: str) -> str | None:
    if len(pattern) < 2 or (pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 2):
        return None
    anchored_domain = False
    anchored_start = False
    anchored_end = False
    if pattern.startswith("||"):
        anchored_domain = True
        pattern = pattern[2:]
    elif pattern.startswith("|"):
        anchored_start = True
        pattern = pattern[1:]
    if pattern.endswith("|"):
        anchored_end = True
        pattern = pattern[:-1]
    if not pattern or pattern == "*":
        return None
    out: list[str] = []
    for char in pattern:
        if char == "*":
            out.append(".*")
        elif char == "^":
            # WebKit url-filters reject disjunctions, so the ABP separator cannot
            # be written as "(class|$)". A separator character still matches the
            # slash or query that real ad URLs have.
            out.append("[^A-Za-z0-9_%.-]")
        elif char in ".+?()[]{}|\\":
            out.append("\\" + char)
        elif char == "$":
            return None
        else:
            out.append(char)
    body = "".join(out)
    if len(body) > 2000 or body.count(".*") > 6:
        return None
    if anchored_domain:
        body = r"^https?://([^/?#]*\.)?" + body
    elif anchored_start:
        body = "^" + body
    if anchored_end:
        body = body + "$"
    return body


def parse_options(raw: str) -> dict | None:
    positive_types: list[str] = []
    negative_types: list[str] = []
    load_type = None
    domains_if: list[str] = []
    domains_unless: list[str] = []
    match_case = False
    bare = False
    for piece in raw.split(","):
        piece = piece.strip()
        if not piece:
            continue
        name, _, value = piece.partition("=")
        negated = name.startswith("~")
        key = name[1:] if negated else name
        key = key.lower()
        if key == "domain":
            for domain in value.split("|"):
                domain = domain.strip().lower()
                if not domain:
                    continue
                if domain.startswith("~"):
                    domains_unless.append(normalize_domain(domain[1:]))
                else:
                    domains_if.append(normalize_domain(domain))
            continue
        if key in RESOURCE_TYPES:
            bucket = negative_types if negated else positive_types
            bucket.append(RESOURCE_TYPES[key])
            continue
        if key in LOAD_TYPES:
            if negated:
                return None
            load_type = LOAD_TYPES[key]
            continue
        if key == "match-case":
            match_case = True
            continue
        if key in BARE_OPTIONS:
            bare = True
            continue
        return None
    if positive_types and negative_types:
        return None
    resource_types = positive_types
    if negative_types:
        resource_types = [item for item in ALL_TYPES if item not in negative_types]
        if not resource_types:
            return None
    domains_if = [item for item in domains_if if item]
    domains_unless = [item for item in domains_unless if item]
    if domains_if and domains_unless:
        return None
    if any(piece.strip().lower().startswith("domain=") or piece.strip().lower().startswith("~domain=") for piece in raw.split(",")):
        if not domains_if and not domains_unless:
            return None
    return {
        "types": resource_types,
        "load": load_type,
        "if": domains_if,
        "unless": domains_unless,
        "case": match_case,
        "bare": bare,
    }


def normalize_domain(domain: str) -> str:
    domain = domain.strip().lower()
    if domain.startswith("*."):
        domain = domain[2:]
    if domain.startswith("www."):
        domain = domain[4:]
    if not domain or " " in domain or "/" in domain or "*" in domain:
        return ""
    if any(ord(char) > 127 for char in domain):
        return ""
    return domain


def trigger(url_filter: str, options: dict | None) -> dict:
    body = {"url-filter": url_filter}
    if not options:
        return body
    if options["types"]:
        body["resource-type"] = options["types"]
    if options["load"]:
        body["load-type"] = [options["load"]]
    if options["if"]:
        body["if-domain"] = options["if"][:1000]
    if options["unless"]:
        body["unless-domain"] = options["unless"][:200]
    if options["case"]:
        body["url-filter-is-case-sensitive"] = True
    return body


def network_rule(line: str) -> dict | None:
    exception = line.startswith("@@")
    body = line[2:] if exception else line
    pattern, _, options_raw = body.partition("$")
    options = parse_options(options_raw) if options_raw else {
        "types": [],
        "load": None,
        "if": [],
        "unless": [],
        "case": False,
        "bare": False,
    }
    if options is None:
        return None
    url_filter = abp_to_regex(pattern.strip())
    if not url_filter:
        return None
    rule = {"trigger": trigger(url_filter, options), "action": {"type": "ignore-previous-rules" if exception else "block"}}
    return rule


def selector_ok(selector: str) -> bool:
    selector = selector.strip()
    if not selector or len(selector) > 400 or selector in {"*", "body", "html", "video", "#movie_player"}:
        return False
    if UNSAFE_SELECTOR.search(selector):
        return False
    return True


def cosmetic_domains(raw: str) -> tuple[bool, list[str], list[str]] | None:
    """Return (global, include, exclude). None drops the rule."""
    if not raw:
        return True, [], []
    include: list[str] = []
    exclude: list[str] = []
    for part in raw.split(","):
        part = part.strip().lower()
        if not part:
            continue
        negated = part.startswith("~")
        domain = normalize_domain(part[1:] if negated else part)
        if not domain:
            return None
        (exclude if negated else include).append(domain)
    if not include and exclude:
        return True, [], exclude
    if include and exclude:
        include = [domain for domain in include if domain not in exclude]
        if not include:
            return None
        return False, include, []
    return False, include, []


class CosmeticBook:
    def __init__(self) -> None:
        self.global_selectors: set[str] = set()
        self.excluded: dict[str, set[str]] = {}
        self.included: dict[str, set[str]] = {}
        self.dropped: set[str] = set()

    def add(self, domains: str, selector: str, exception: bool) -> None:
        if not selector_ok(selector):
            return
        if exception and not domains:
            self.dropped.add(selector)
            return
        parsed = cosmetic_domains(domains)
        if parsed is None:
            return
        is_global, include, exclude = parsed
        if exception:
            self.excluded.setdefault(selector, set()).update(include)
            self.excluded.setdefault(selector, set()).update(exclude)
            return
        if is_global:
            self.global_selectors.add(selector)
            self.excluded.setdefault(selector, set()).update(exclude)
            return
        self.included.setdefault(selector, set()).update(include)

    def rules(self) -> list[dict]:
        compiled: list[dict] = []
        selectors = set(self.global_selectors) | set(self.included) | set(self.excluded)
        for selector in sorted(selectors):
            if selector in self.dropped:
                continue
            excluded = self.excluded.get(selector, set())
            if selector in self.global_selectors:
                if len(excluded) > 200:
                    continue
                trigger_body: dict = {"url-filter": ".*"}
                if excluded:
                    trigger_body["unless-domain"] = sorted(excluded)
                compiled.append(
                    {"trigger": trigger_body, "action": {"type": "css-display-none", "selector": selector}}
                )
                continue
            include = sorted(self.included.get(selector, set()) - excluded)
            if not include:
                continue
            for start in range(0, len(include), 800):
                chunk = include[start : start + 800]
                compiled.append(
                    {
                        "trigger": {"url-filter": ".*", "if-domain": chunk},
                        "action": {"type": "css-display-none", "selector": selector},
                    }
                )
        return compiled


def convert_text(text: str) -> tuple[list[dict], list[dict], list[dict]]:
    blocks: list[dict] = []
    exceptions: list[dict] = []
    cosmetics = CosmeticBook()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("!") or line.startswith("["):
            continue
        if "#@#" in line:
            domains, _, selector = line.partition("#@#")
            cosmetics.add(domains, selector, True)
            continue
        if "#?#" in line or "#$#" in line or "#%#" in line:
            continue
        if "##" in line:
            domains, _, selector = line.partition("##")
            if "://" in domains:
                continue
            cosmetics.add(domains, selector, False)
            continue
        rule = network_rule(line)
        if not rule:
            continue
        if rule["action"]["type"] == "ignore-previous-rules":
            exceptions.append(rule)
        else:
            blocks.append(rule)
    return blocks, cosmetics.rules(), exceptions


def is_protected(rule: dict) -> bool:
    if rule["action"]["type"] != "block":
        return False
    pattern = rule["trigger"]["url-filter"]
    if pattern == ".*":
        return True
    interesting = (
        "youtube",
        "googlevideo",
        "ytimg",
        "gstatic",
        "googleapis",
        "google.com",
        "yandex",
        "yastatic",
        "ya.ru",
    )
    if not any(piece in pattern for piece in interesting):
        return False
    try:
        compiled = re.compile(pattern, re.IGNORECASE)
    except re.error:
        return True
    return any(compiled.search(url) for url in PROTECTED_URLS)


def encoded_size(rule: dict) -> int:
    return len(json.dumps(rule, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def fit(blocks: list[dict], cosmetics: list[dict], exceptions: list[dict]) -> list[dict]:
    safe_blocks = [rule for rule in blocks if not is_protected(rule)]
    base = safe_blocks + exceptions
    base_size = len(json.dumps(base, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    if len(base) > MAX_RULES or base_size > MAX_BYTES:
        raise SystemExit(f"network rules alone exceed the Safari budget ({len(base)} rules, {base_size} bytes)")
    kept_cosmetics: list[dict] = []
    size = base_size
    room = MAX_RULES - len(base)
    def cosmetic_rank(rule: dict) -> tuple:
        selector = rule["action"].get("selector", "")
        hot = ("ytd-", "ytp-ad", "adsbygoogle", "google_ads", "masthead", "yandex_rtb", "adfox", "yandex-rtb")
        return (0 if any(piece in selector for piece in hot) else 1, selector)

    for rule in sorted(cosmetics, key=cosmetic_rank):
        if room <= 0:
            break
        extra = encoded_size(rule) + 1
        if size + extra > MAX_BYTES:
            continue
        kept_cosmetics.append(rule)
        size += extra
        room -= 1
    return safe_blocks + kept_cosmetics + exceptions


def dumps(rules: list[dict]) -> str:
    return json.dumps(rules, separators=(",", ":"), ensure_ascii=False)


def self_test() -> None:
    samples = {
        "||doubleclick.net^": True,
        "||pagead2.googlesyndication.com^": True,
        "@@||example.com^": True,
        "/banner.js$script,third-party": True,
        "||ads.example.com^$csp=script-src 'none'": False,
        "example.com##.adsbox": True,
        "example.com##.ad:has(.x)": False,
        "@@||youtube.com/get_video_info?$xmlhttprequest,domain=music.youtube.com": True,
    }
    for line, kept in samples.items():
        blocks, cosmetics, exceptions = convert_text(line + "\n")
        got = bool(blocks or cosmetics or exceptions)
        if got != kept:
            raise SystemExit(f"{line!r} kept={got}, expected {kept}")
    pattern = abp_to_regex("||doubleclick.net^")
    assert pattern is not None
    assert "|" not in pattern
    compiled = re.compile(pattern, re.IGNORECASE)
    assert compiled.search("https://ad.doubleclick.net/ddm/track")
    assert not compiled.search("https://notdoubleclick.net/")
    assert not compiled.search("https://www.youtube.com/watch?v=abc")
    yandex = yandex_ad_rules()

    def hits(rules: list[dict], url: str) -> bool:
        return any(
            rule["action"]["type"] == "block" and re.search(rule["trigger"]["url-filter"], url, re.IGNORECASE)
            for rule in rules
        )

    assert hits(yandex, "https://an.yandex.ru/system/context.js")
    assert hits(yandex, "https://yandex.ru/ads/system/context.js")
    assert hits(yandex, "https://yastatic.net/partner-code/context.js")
    assert not hits(yandex, "https://yandex.ru/")
    assert not hits(yandex, "https://yandex.ru/maps/213/moscow/")
    assert not hits(yandex, "https://ya.ru/")
    assert hits(yandex_privacy_rules(), "https://mc.yandex.ru/watch/123")
    assert not hits(yandex_privacy_rules(), "https://yandex.ru/")
    sample = parse_scriptlet("example.com##+js(set-constant, canRunAds, false)")
    assert sample and sample["name"] == "set-constant"
    assert parse_scriptlet("##+js(set-constant, canRunAds, false)") is None
    procedural = parse_procedural('rifme.net#?#div:-abp-has(> [id^="yandex_rtb"])')
    assert procedural and procedural["kind"] == "css"


SUPPORTED_SCRIPTLETS = {
    "set-constant": "set-constant",
    "set": "set-constant",
    "abort-on-property-read": "abort-on-property-read",
    "abort-on-property-write": "abort-on-property-write",
    "json-prune": "json-prune",
    "remove-node-text": "remove-node-text",
    "rmnt": "remove-node-text",
    "prevent-fetch": "prevent-fetch",
    "prevent-xhr": "prevent-xhr",
    "no-fetch-if": "prevent-fetch",
    "no-xhr-if": "prevent-xhr",
}
FORBIDDEN_PROPERTIES = {
    "document", "window", "location", "cookie", "length", "prototype",
    "href", "src", "parentNode", "innerHTML",
}


def host_block(host: str) -> dict:
    pattern = abp_to_regex(f"||{host}^")
    if not pattern:
        raise SystemExit(f"could not compile host rule {host}")
    return {"trigger": {"url-filter": pattern}, "action": {"type": "block"}}


def path_block(host: str, path: str) -> dict:
    escaped = host.replace(".", r"\.")
    return {
        "trigger": {"url-filter": rf"^https?://([^/?#]*\.)?{escaped}{path}"},
        "action": {"type": "block"},
    }


def cosmetic_rule(selector: str) -> dict:
    return {"trigger": {"url-filter": ".*"}, "action": {"type": "css-display-none", "selector": selector}}


def yandex_ad_rules() -> list[dict]:
    rules = [host_block(host) for host in (
        "an.yandex.ru", "yabs.yandex.ru", "adfox.yandex.ru", "ads.adfox.ru", "yandexadexchange.net",
    )]
    rules += [
        path_block("yandex.ru", "/ads/"),
        path_block("yandex.ru", "/an/"),
        path_block("yandex.com", "/ads/"),
        path_block("yastatic.net", "/partner-code"),
        path_block("yastatic.net", "/pcode/"),
        path_block("yastatic.net", "/safeframe-bundles/"),
        cosmetic_rule('div[id^="yandex_rtb"]'),
        cosmetic_rule('div[class^="yandex_rtb"]'),
        cosmetic_rule('div[id^="adfox_"]'),
        cosmetic_rule(".yandex-rtb"),
        cosmetic_rule(".yandex-rtb-block"),
        cosmetic_rule('iframe[src*="an.yandex.ru"]'),
        cosmetic_rule('iframe[src*="yandex.ru/ads"]'),
        cosmetic_rule('iframe[src*="adfox.yandex"]'),
    ]
    return [rule for rule in rules if not is_protected(rule)]


def yandex_privacy_rules() -> list[dict]:
    rules = [host_block(host) for host in ("mc.yandex.ru", "mc.yandex.com", "mc.yandex.by", "mc.yandex.kz")]
    return [rule for rule in rules if not is_protected(rule)]


def split_scriptlet_args(raw: str) -> list[str]:
    args: list[str] = []
    current: list[str] = []
    quote = ""
    for char in raw.strip():
        if quote:
            if char == quote:
                quote = ""
            else:
                current.append(char)
            continue
        if char in {"'", '"'}:
            quote = char
            continue
        if char == ",":
            args.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    tail = "".join(current).strip()
    if tail:
        args.append(tail)
    return [item for item in args if item]


def normalize_domains(raw: str) -> list[str]:
    domains: list[str] = []
    for part in raw.split(","):
        text = part.strip().lower()
        if not text or text.startswith("~") or "*" in text:
            continue
        if text.startswith("*."):
            text = text[2:]
        if text.startswith("www."):
            text = text[4:]
        if text and " " not in text and "/" not in text:
            domains.append(text)
    return domains[:8]


def extract_engines(texts: list[str]) -> tuple[list[dict], list[dict]]:
    scriptlets: list[dict] = []
    procedural: list[dict] = []
    seen_s: set[str] = set()
    seen_p: set[str] = set()
    for text in texts:
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("!") or line.startswith("["):
                continue
            if "##+js(" in line or "#%#//scriptlet" in line or "#%#//scriptlet(" in line:
                rule = parse_scriptlet(line)
                if not rule:
                    continue
                key = json.dumps(rule, ensure_ascii=False, sort_keys=True)
                if key in seen_s or len(scriptlets) >= MAX_SCRIPTLETS:
                    continue
                seen_s.add(key)
                scriptlets.append(rule)
                continue
            if "#?#" not in line:
                continue
            rule = parse_procedural(line)
            if not rule:
                continue
            key = json.dumps(rule, ensure_ascii=False, sort_keys=True)
            if key in seen_p or len(procedural) >= MAX_PROCEDURAL:
                continue
            seen_p.add(key)
            procedural.append(rule)
    return scriptlets, procedural


def parse_scriptlet(line: str) -> dict | None:
    if "##+js(" in line:
        domains_raw, _, call = line.partition("##+js(")
        if not call.endswith(")"):
            return None
        parts = split_scriptlet_args(call[:-1])
    else:
        domains_raw, _, call = line.partition("#%#")
        call = call.strip()
        if not call.startswith("//scriptlet"):
            return None
        open_paren = call.find("(")
        close_paren = call.rfind(")")
        if open_paren < 0 or close_paren < 0:
            return None
        parts = split_scriptlet_args(call[open_paren + 1 : close_paren])
    if not parts:
        return None
    name = SUPPORTED_SCRIPTLETS.get(parts[0].strip().strip("'\""))
    if not name:
        return None
    domains = normalize_domains(domains_raw)
    if not domains:
        return None
    args = [part.strip().strip("'\"") for part in parts[1:]]
    if name in {"abort-on-property-read", "abort-on-property-write", "set-constant"}:
        prop = args[0].split(".")[-1] if args else ""
        if not prop or prop in FORBIDDEN_PROPERTIES or len(prop) < 4:
            return None
    if name == "json-prune":
        keys = [key for key in " ".join(args).replace(",", " ").split() if len(key) >= 4]
        if not keys:
            return None
        args = keys[:12]
    if name == "remove-node-text":
        needle = args[-1] if args else ""
        if len(needle) < 6 or len(needle) > 80:
            return None
    if name in {"prevent-fetch", "prevent-xhr"}:
        token = args[0] if args else ""
        if len(token) < 8:
            return None
    return {"domains": domains, "name": name, "args": args[:6]}


def parse_procedural(line: str) -> dict | None:
    domains_raw, _, selector = line.partition("#?#")
    selector = selector.strip()
    if not selector or len(selector) > 280:
        return None
    if selector in {"*", "body", "html", "div", "span", "a"} or selector.startswith("body"):
        return None
    domains = normalize_domains(domains_raw)
    lowered = selector.lower()
    global_ok = any(token in lowered for token in ("yandex_rtb", "adfox", "adsbygoogle", "taboola", "outbrain"))
    if not domains and not global_ok:
        return None
    kind = "css"
    if ":has-text" in lowered or ":-abp-contains" in lowered:
        kind = "text"
    elif ":upward" in lowered:
        kind = "upward"
    elif ":-abp-has" in lowered or ":has(" in lowered:
        kind = "css"
    else:
        return None
    if kind == "text":
        match = re.search(r":(?:-abp-)?(?:has-text|contains)\(([^)]+)\)", selector, re.I)
        if not match or len(match.group(1).strip("'\"")) < 6:
            return None
    return {"domains": domains, "selector": selector, "kind": kind}


def engine_rules_js(scriptlets: list[dict], procedural: list[dict]) -> str:
    payload = json.dumps({"scriptlets": scriptlets, "procedural": procedural}, ensure_ascii=False, separators=(",", ":"))
    return "globalThis.QUIETSAFARI_ENGINE_RULES = " + payload + ";\n"


def build_from(ads_text: str, privacy_text: str, russian_text: str) -> tuple[str, str, str, str, dict]:
    ads = fit(*convert_text(ads_text))
    privacy = fit(*convert_text(privacy_text)) + yandex_privacy_rules()
    russian = fit(*convert_text(russian_text)) + yandex_ad_rules()
    scriptlets, procedural = extract_engines([ads_text, privacy_text, russian_text])
    ads_json = dumps(ads)
    privacy_json = dumps(privacy)
    russian_json = dumps(russian)
    summary = {
        "ads": len(ads),
        "ads_bytes": len(ads_json.encode("utf-8")),
        "privacy": len(privacy),
        "privacy_bytes": len(privacy_json.encode("utf-8")),
        "russian": len(russian),
        "russian_bytes": len(russian_json.encode("utf-8")),
        "scriptlets": len(scriptlets),
        "procedural": len(procedural),
    }
    return ads_json, privacy_json, russian_json, engine_rules_js(scriptlets, procedural), summary


def main() -> None:
    self_test()
    ads_text = download(EASYLIST_URL, "easylist.txt")
    privacy_text = download(EASYPRIVACY_URL, "easyprivacy.txt")
    russian_text = download(RU_ADLIST_URL, "advblock.txt")
    ads_json, privacy_json, russian_json, engine_js, summary = build_from(ads_text, privacy_text, russian_text)
    if "--check" in sys.argv:
        current = {
            ADS_OUT: ads_json,
            PRIVACY_OUT: privacy_json,
            RUSSIAN_OUT: russian_json,
            ENGINE_RULES_OUT: engine_js,
        }
        stale = [path.name for path, text in current.items() if not path.exists() or path.read_text(encoding="utf-8") != text]
        if stale:
            raise SystemExit("shipped filters are stale: " + ", ".join(stale) + f" {summary}")
        print("shipped filters match", summary)
        return
    ADS_OUT.write_text(ads_json, encoding="utf-8")
    PRIVACY_OUT.write_text(privacy_json, encoding="utf-8")
    RUSSIAN_OUT.write_text(russian_json, encoding="utf-8")
    ENGINE_RULES_OUT.write_text(engine_js, encoding="utf-8")
    counts = {
        "version": 4,
        "adCount": summary["ads"],
        "privacyCount": summary["privacy"],
        "russianCount": summary["russian"],
        "scriptlets": summary["scriptlets"],
        "procedural": summary["procedural"],
    }
    (ROOT / "Shared" / "filter-counts.json").write_text(json.dumps(counts, indent=2) + "\n", encoding="utf-8")
    print(
        f"ads {summary['ads']} ({summary['ads_bytes']} B), "
        f"privacy {summary['privacy']} ({summary['privacy_bytes']} B), "
        f"russian {summary['russian']} ({summary['russian_bytes']} B), "
        f"scriptlets {summary['scriptlets']}, procedural {summary['procedural']}"
    )


if __name__ == "__main__":
    main()
