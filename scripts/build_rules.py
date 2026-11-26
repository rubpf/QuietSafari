#!/usr/bin/env python3
"""Build the small proof content-blocker list.

These rules are original. They are not a copy of EasyList. The full lists are
downloaded and converted in a later stage; this file only has to be enough for
the owner to see that Safari is applying rules.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Shared" / "blockerList.json"

# Obvious ad and tracker hosts. youtube.com and googlevideo.com are intentionally absent:
# blocking them would stop real videos.
BLOCK_DOMAINS = [
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "googletagservices.com",
    "amazon-adsystem.com",
    "adnxs.com",
    "adsrvr.org",
    "pubmatic.com",
    "rubiconproject.com",
    "criteo.com",
    "criteo.net",
    "taboola.com",
    "outbrain.com",
    "moatads.com",
    "scorecardresearch.com",
    "2mdn.net",
    "adform.net",
    "serving-sys.com",
    "adservice.google.com",
]

COSMETIC_SELECTORS = [
    "ins.adsbygoogle",
    ".adsbygoogle",
    'iframe[src*="doubleclick.net"]',
    'iframe[src*="googlesyndication.com"]',
    'iframe[id^="google_ads_iframe"]',
    'div[id^="google_ads_iframe"]',
    'div[id^="div-gpt-ad"]',
]

# In-feed and banner slots only. The player overlay stays visible so YouTube's
# own skip button still works when the content script cannot run.
YOUTUBE_SELECTORS = [
    "ytd-ad-slot-renderer",
    "ytd-banner-promo-renderer",
    "ytd-video-masthead-ad-advertiser-info-renderer",
    "ytd-video-masthead-ad-v3-renderer",
    "ytd-primetime-promo-renderer",
    "ytd-in-feed-ad-layout-renderer",
    "ytd-statement-banner-renderer",
    "#player-ads",
    "#masthead-ad",
]


def host_pattern(host: str) -> str:
    """Match the host and its subdomains, and not a look-alike or a path."""
    escaped = host.replace(".", r"\.")
    return rf"^https?://([^/?#]*\.)?{escaped}([:/?#]|$)"


def rules() -> list[dict]:
    compiled: list[dict] = []
    for host in BLOCK_DOMAINS:
        compiled.append(
            {
                "trigger": {"url-filter": host_pattern(host)},
                "action": {"type": "block"},
            }
        )
    compiled.append(
        {
            "trigger": {"url-filter": ".*"},
            "action": {
                "type": "css-display-none",
                "selector": ", ".join(COSMETIC_SELECTORS),
            },
        }
    )
    compiled.append(
        {
            "trigger": {
                "url-filter": ".*",
                "if-domain": ["youtube.com", "youtube-nocookie.com"],
            },
            "action": {
                "type": "css-display-none",
                "selector": ", ".join(YOUTUBE_SELECTORS),
            },
        }
    )
    return compiled


def rules_text() -> str:
    return json.dumps(rules(), indent=2, ensure_ascii=False) + "\n"


def _matches(pattern: str, url: str) -> bool:
    return re.search(pattern, url, flags=re.IGNORECASE) is not None


def self_test() -> None:
    compiled = rules()
    by_host = {}
    for rule in compiled:
        action = rule["action"]["type"]
        if action == "block":
            pattern = rule["trigger"]["url-filter"]
            by_host[pattern] = pattern

    samples = {
        "doubleclick.net": [
            ("https://ad.doubleclick.net/ddm/trackclk", True),
            ("https://doubleclick.net/", True),
            ("https://googleads.g.doubleclick.net/pagead/id", True),
            ("http://doubleclick.net:443/pixel", True),
            ("https://notdoubleclick.net/", False),
            ("https://doubleclick.net.evil.com/", False),
            ("https://www.google.com/search?q=doubleclick.net", False),
        ],
        "googlesyndication.com": [
            ("https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", True),
            ("https://example.com/pagead2.googlesyndication.com", False),
        ],
        "adservice.google.com": [
            ("https://adservice.google.com/adsid/integrator.js", True),
            ("https://www.google.com/", False),
            ("https://adservice.google.com.evil.com/", False),
        ],
        "amazon-adsystem.com": [
            ("https://aax.amazon-adsystem.com/e/x", True),
            ("https://www.amazon.com/", False),
        ],
        "2mdn.net": [
            ("https://s0.2mdn.net/ads/studio", True),
        ],
        "taboola.com": [
            ("https://cdn.taboola.com/lib.js", True),
            ("https://nottaboola.com/", False),
        ],
    }
    patterns = {host: host_pattern(host) for host in samples}
    for host, cases in samples.items():
        pattern = patterns[host]
        assert pattern in by_host.values()
        for url, expected in cases:
            got = _matches(pattern, url)
            if got != expected:
                raise SystemExit(f"{host} pattern {pattern!r} on {url} -> {got}, expected {expected}")

    for url in (
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/",
        "https://r1---sn.googlevideo.com/videoplayback?id=1",
        "https://i.ytimg.com/vi/abc/hqdefault.jpg",
        "https://fonts.googleapis.com/css?family=Inter",
        "https://www.gstatic.com/images/branding.png",
    ):
        for pattern in by_host.values():
            if _matches(pattern, url):
                raise SystemExit(f"proof list blocked a page it must leave alone: {url} via {pattern}")

    types = {rule["action"]["type"] for rule in compiled}
    if types != {"block", "css-display-none"}:
        raise SystemExit(f"unexpected action types: {types}")
    if len(compiled) != len(BLOCK_DOMAINS) + 2:
        raise SystemExit("unexpected rule count")


def main() -> None:
    self_test()
    OUTPUT.write_text(rules_text(), encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(rules())} rules)")


if __name__ == "__main__":
    main()
