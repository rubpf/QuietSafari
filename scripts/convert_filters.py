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

EASYLIST_URL = "https://easylist.to/easylist/easylist.txt"
EASYPRIVACY_URL = "https://easylist.to/easylist/easyprivacy.txt"

MAX_RULES = 140_000
MAX_BYTES = 7_200_000

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
            out.append("([^A-Za-z0-9_%.-]|$)")
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
    interesting = ("youtube", "googlevideo", "ytimg", "gstatic", "googleapis", "google.com")
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
        hot = ("ytd-", "ytp-ad", "adsbygoogle", "google_ads", "masthead")
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
    compiled = re.compile(pattern, re.IGNORECASE)
    assert compiled.search("https://ad.doubleclick.net/ddm/track")
    assert not compiled.search("https://notdoubleclick.net/")
    assert not compiled.search("https://www.youtube.com/watch?v=abc")


def build_from(ads_text: str, privacy_text: str) -> tuple[str, str, dict]:
    ads = fit(*convert_text(ads_text))
    privacy = fit(*convert_text(privacy_text))
    ads_json = dumps(ads)
    privacy_json = dumps(privacy)
    summary = {
        "ads": len(ads),
        "ads_bytes": len(ads_json.encode("utf-8")),
        "privacy": len(privacy),
        "privacy_bytes": len(privacy_json.encode("utf-8")),
    }
    return ads_json, privacy_json, summary


def main() -> None:
    self_test()
    ads_text = download(EASYLIST_URL, "easylist.txt")
    privacy_text = download(EASYPRIVACY_URL, "easyprivacy.txt")
    ads_json, privacy_json, summary = build_from(ads_text, privacy_text)
    if "--check" in sys.argv:
        current_ads = ADS_OUT.read_text(encoding="utf-8") if ADS_OUT.exists() else ""
        current_privacy = PRIVACY_OUT.read_text(encoding="utf-8") if PRIVACY_OUT.exists() else ""
        if current_ads != ads_json or current_privacy != privacy_json:
            raise SystemExit(
                "shipped filter JSON is stale "
                f"(ads {summary['ads']} rules / {summary['ads_bytes']} bytes, "
                f"privacy {summary['privacy']} rules / {summary['privacy_bytes']} bytes). "
                "Run scripts/convert_filters.py"
            )
        print("shipped filters match", summary)
        return
    ADS_OUT.write_text(ads_json, encoding="utf-8")
    PRIVACY_OUT.write_text(privacy_json, encoding="utf-8")
    counts = {
        "version": 2,
        "adCount": summary["ads"],
        "privacyCount": summary["privacy"],
    }
    (ROOT / "Shared" / "filter-counts.json").write_text(json.dumps(counts, indent=2) + "\n", encoding="utf-8")
    print(
        f"ads {summary['ads']} rules, {summary['ads_bytes']} bytes; "
        f"privacy {summary['privacy']} rules, {summary['privacy_bytes']} bytes"
    )


if __name__ == "__main__":
    main()
