#!/usr/bin/env python3
"""Check the scaffold without Xcode: JSON, manifests, plists, and the generated project."""

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import convert_filters  # noqa: E402


def fail(message: str) -> None:
    raise SystemExit(message)


def normalize(raw: str):
    """Mirror of DomainNormalizer.normalize in App/RuleCompiler.swift."""
    text = raw.strip().lower()
    if text.startswith("https://"):
        text = text[len("https://") :]
    elif text.startswith("http://"):
        text = text[len("http://") :]
    for separator in "/?#":
        if separator in text:
            text = text[: text.index(separator)]
            break
    if ":" in text:
        text = text[: text.index(":")]
    if text.startswith("www."):
        text = text[4:]
    if len(text) > 253:
        return None
    if text == "localhost":
        return text

    def host_char(char: str) -> bool:
        return ("a" <= char <= "z") or ("0" <= char <= "9")

    def valid_label(label: str) -> bool:
        if not 1 <= len(label) <= 63:
            return False
        if not host_char(label[0]) or not host_char(label[-1]):
            return False
        return all(host_char(char) or char == "-" for char in label)

    labels = text.split(".")
    if len(labels) < 2 or not all(valid_label(label) for label in labels):
        return None
    return text


def check_normalizer() -> None:
    cases = {
        "Example.COM": "example.com",
        "https://www.Example.com/path": "example.com",
        "http://example.com:8080/a?b=1": "example.com",
        "www.youtube.com": "youtube.com",
        "https://www.YouTube.com/watch?v=1": "youtube.com",
        "localhost": "localhost",
        "127.0.0.1": "127.0.0.1",
        "a.b": "a.b",
        "not a domain": None,
        "*.example.com": None,
        "example": None,
        "example..com": None,
        "-bad.com": None,
        "bad-.com": None,
        "": None,
        "example.com.": None,
        "https://example.com.": None,
    }
    for raw, expected in cases.items():
        got = normalize(raw)
        if got != expected:
            fail(f"normalize({raw!r}) -> {got!r}, expected {expected!r}")


def check_rules() -> None:
    convert_filters.self_test()
    import validate_safari_rules

    validate_safari_rules.main()
    allowed_actions = {"block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https"}
    protected = [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/",
        "https://rr1---sn-xxxx.googlevideo.com/videoplayback?id=1",
        "https://www.google.com/",
        "https://yandex.ru/",
        "https://ya.ru/",
        "https://yandex.ru/maps/213/moscow/",
        "https://yastatic.net/s3/home-static/logo.png",
    ]
    for name, minimum in (("blockerList.json", 20000), ("privacyList.json", 20000), ("russianList.json", 8000)):
        path = ROOT / "Shared" / name
        raw = path.read_bytes()
        if len(raw) > 7_500_000:
            fail(f"{name} is {len(raw)} bytes, over the Safari size budget")
        compiled = json.loads(raw)
        if not isinstance(compiled, list) or len(compiled) < minimum or len(compiled) > 150_000:
            fail(f"{name} has an unexpected rule count: {len(compiled) if isinstance(compiled, list) else 'not a list'}")
        for rule in compiled[:50]:
            action = (rule.get("action") or {}).get("type")
            if action not in allowed_actions or not (rule.get("trigger") or {}).get("url-filter"):
                fail(f"{name} has a malformed rule")
        for rule in compiled:
            if (rule.get("action") or {}).get("type") != "block":
                continue
            pattern = rule["trigger"]["url-filter"]
            if pattern == ".*":
                fail(f"{name} has a block-everything rule")
            if not any(piece in pattern for piece in ("youtube", "googlevideo", "ytimg", "google.com", "yandex", "yastatic", "ya.ru")):
                continue
            try:
                compiled_re = re.compile(pattern, re.IGNORECASE)
            except re.error as error:
                fail(f"bad regex in {name}: {error}")
            for url in protected:
                if compiled_re.search(url):
                    fail(f"{name} would block {url} via {pattern}")
    ads = json.loads((ROOT / "Shared" / "blockerList.json").read_text(encoding="utf-8"))
    selectors = "\n".join(
        (rule.get("action") or {}).get("selector", "")
        for rule in ads
        if (rule.get("action") or {}).get("type") == "css-display-none"
    )
    if "adsbygoogle" not in selectors:
        fail("EasyList conversion dropped the adsbygoogle cosmetic rule")
    russian = json.loads((ROOT / "Shared" / "russianList.json").read_text(encoding="utf-8"))

    def hits(rules: list, url: str) -> bool:
        for rule in rules:
            if (rule.get("action") or {}).get("type") != "block":
                continue
            pattern = rule["trigger"]["url-filter"]
            if "yandex" not in pattern and "yastatic" not in pattern and "adfox" not in pattern:
                continue
            if re.search(pattern, url, re.IGNORECASE):
                return True
        return False

    if not hits(russian, "https://an.yandex.ru/system/context.js"):
        fail("russian list does not block an.yandex.ru")
    if not hits(russian, "https://yandex.ru/ads/system/context.js"):
        fail("russian list does not block yandex.ru/ads")
    if not hits(russian, "https://yastatic.net/partner-code/context.js"):
        fail("russian list does not block yastatic partner code")
    russian_selectors = "\n".join(
        (rule.get("action") or {}).get("selector", "")
        for rule in russian
        if (rule.get("action") or {}).get("type") == "css-display-none"
    )
    if 'div[id^="yandex_rtb"]' not in russian_selectors:
        fail("russian list is missing the yandex_rtb cosmetic rule")
    privacy = json.loads((ROOT / "Shared" / "privacyList.json").read_text(encoding="utf-8"))
    if not hits(privacy, "https://mc.yandex.ru/watch/1"):
        fail("privacy list does not block mc.yandex.ru")
    if hits(russian, "https://mc.yandex.ru/watch/1") and not hits(privacy, "https://mc.yandex.ru/watch/1"):
        fail("mc.yandex.ru must stay on the privacy list")
    engine = (ROOT / "Extension" / "Resources" / "engine.js").read_text(encoding="utf-8")
    for needle in ("set-constant", "abort-on-property-read", "json-prune", "MutationObserver", ":has("):
        if needle not in engine:
            fail(f"engine.js missing {needle}")
    rules_js = (ROOT / "Extension" / "Resources" / "engine-rules.js").read_text(encoding="utf-8")
    if "QUIETSAFARI_ENGINE_RULES" not in rules_js:
        fail("engine-rules.js was not generated")
    youtube = (ROOT / "Extension" / "Resources" / "youtube.js").read_text(encoding="utf-8")
    main = (ROOT / "Extension" / "Resources" / "youtube-main.js").read_text(encoding="utf-8")
    for needle in ("ytd-ad-slot-renderer", "ad-showing", "movie_player"):
        if needle not in youtube:
            fail(f"youtube.js missing {needle}")
    for needle in ("adPlacements", "ytInitialPlayerResponse", "JSON.parse"):
        if needle not in main:
            fail(f"youtube-main.js missing {needle}")


def check_manifest() -> None:
    manifest_path = ROOT / "Extension" / "Resources" / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("manifest_version") != 3:
        fail("manifest is not version 3")
    if manifest.get("version") != "0.3.0":
        fail("manifest version drifted from 0.3.0")
    background = manifest.get("background") or {}
    if background.get("service_worker") != "background.js":
        fail("background service worker path is wrong")
    for key in ("nativeMessaging", "storage"):
        if key not in manifest.get("permissions", []):
            fail(f"manifest missing permission {key}")
    resources = ROOT / "Extension" / "Resources"
    for name in ("background.js", "cosmetic.js", "youtube.js", "youtube-main.js", "popup.html", "popup.css", "popup.js", "engine.js", "engine-rules.js", "cookies.js"):
        if not (resources / name).exists():
            fail(f"missing {name}")
    for icon in manifest.get("icons", {}).values():
        if not (resources / icon).exists():
            fail(f"manifest icon missing: {icon}")
    scripts = [script for entry in manifest.get("content_scripts", []) for script in entry.get("js", [])]
    if "youtube.js" not in scripts or "youtube-main.js" not in scripts or "cosmetic.js" not in scripts:
        fail("content scripts are not registered")
    if "engine.js" not in scripts or "engine-rules.js" not in scripts or "cookies.js" not in scripts:
        fail("engine or cookie script is not registered")
    cosmetic_entry = next(entry for entry in manifest.get("content_scripts", []) if "cosmetic.js" in entry.get("js", []))
    if cosmetic_entry.get("run_at") != "document_start":
        fail("cosmetic.js must run at document_start so an ad script cannot delay it")
    worlds = [entry.get("world") for entry in manifest.get("content_scripts", [])]
    if "MAIN" not in worlds:
        fail("YouTube page-world script is not declared")


def check_plists() -> None:
    app = plistlib.loads((ROOT / "App" / "Info.plist").read_bytes())
    extension = plistlib.loads((ROOT / "Extension" / "Info.plist").read_bytes())
    blocker = plistlib.loads((ROOT / "ContentBlocker" / "Info.plist").read_bytes())
    group = "$(TeamIdentifierPrefix)com.quietsafari.shared"
    for name, plist in ("app", app), ("extension", extension), ("blocker", blocker):
        if plist.get("QuietSafariAppGroup") != group:
            fail(f"{name} Info.plist has a different app group")
    ext_point = extension["NSExtension"]["NSExtensionPointIdentifier"]
    blocker_point = blocker["NSExtension"]["NSExtensionPointIdentifier"]
    if ext_point != "com.apple.Safari.web-extension":
        fail(f"unexpected web extension point {ext_point}")
    if blocker_point != "com.apple.Safari.content-blocker":
        fail(f"unexpected content blocker point {blocker_point}")
    if "SafariWebExtensionHandler" not in extension["NSExtension"]["NSExtensionPrincipalClass"]:
        fail("web extension principal class is wrong")
    if "ContentBlockerRequestHandler" not in blocker["NSExtension"]["NSExtensionPrincipalClass"]:
        fail("content blocker principal class is wrong")
    if blocker.get("CFBundleDisplayName") != "QuietSafari Content Blocker":
        fail("content blocker display name drifted from the README")
    privacy = plistlib.loads((ROOT / "Privacy" / "Info.plist").read_bytes())
    if privacy["NSExtension"]["NSExtensionPointIdentifier"] != "com.apple.Safari.content-blocker":
        fail("privacy extension is not a content blocker")
    if privacy.get("CFBundleDisplayName") != "QuietSafari Privacy":
        fail("privacy display name drifted")
    if privacy.get("QuietSafariRulesName") != "privacyList.json":
        fail("privacy rules file name drifted")
    russian_plist = plistlib.loads((ROOT / "Russian" / "Info.plist").read_bytes())
    if russian_plist["NSExtension"]["NSExtensionPointIdentifier"] != "com.apple.Safari.content-blocker":
        fail("russian extension is not a content blocker")
    if russian_plist.get("CFBundleDisplayName") != "QuietSafari Russian":
        fail("russian display name drifted")
    if russian_plist.get("QuietSafariRulesName") != "russianList.json":
        fail("russian rules file name drifted")
    for relative in (
        "App/QuietSafari.entitlements",
        "Extension/QuietSafariExtension.entitlements",
        "ContentBlocker/QuietSafariContentBlocker.entitlements",
    ):
        data = plistlib.loads((ROOT / relative).read_bytes())
        groups = data.get("com.apple.security.application-groups")
        if groups != [group]:
            fail(f"{relative} app group mismatch: {groups}")
        if data.get("com.apple.security.app-sandbox") is not True:
            fail(f"{relative} is not sandboxed")
    adhoc = {
        "App/QuietSafariAdHoc.entitlements": True,
        "Extension/QuietSafariExtensionAdHoc.entitlements": False,
        "ContentBlocker/QuietSafariBlockerAdHoc.entitlements": False,
    }
    shared_folder = "Library/Application Support/QuietSafari/"
    for relative, needs_network in adhoc.items():
        data = plistlib.loads((ROOT / relative).read_bytes())
        if data.get("com.apple.security.app-sandbox") is not True:
            fail(f"{relative} is not sandboxed")
        if "com.apple.security.application-groups" in data:
            fail(f"{relative} still requires a team app group")
        paths = data.get("com.apple.security.temporary-exception.files.home-relative-path.read-write")
        if paths != [shared_folder]:
            fail(f"{relative} is missing the ad-hoc shared folder")
        if needs_network and data.get("com.apple.security.network.client") is not True:
            fail(f"{relative} cannot download filter lists")
    xcconfig = (ROOT / "Config" / "Shared.xcconfig").read_text(encoding="utf-8")
    for key in (
        "QUIETSAFARI_APP_ENTITLEMENTS = App/QuietSafari.entitlements",
        "QUIETSAFARI_EXTENSION_ENTITLEMENTS = Extension/QuietSafariExtension.entitlements",
        "QUIETSAFARI_BLOCKER_ENTITLEMENTS = ContentBlocker/QuietSafariContentBlocker.entitlements",
    ):
        if key not in xcconfig:
            fail(f"xcconfig missing {key}")
    for relative in (
        ".github/workflows/release.yml",
        ".github/workflows/pages.yml",
        "scripts/build_release.sh",
        "homebrew-tap/Casks/quietsafari.rb",
        "site/index.html",
    ):
        if not (ROOT / relative).exists():
            fail(f"missing {relative}")
    release = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    for needle in ("macos-latest", "scripts/build_release.sh", "QuietSafari.zip", "v*"):
        if needle not in release:
            fail(f"release workflow missing {needle}")
    build = (ROOT / "scripts/build_release.sh").read_text(encoding="utf-8")
    for needle in ("CODE_SIGN_IDENTITY=-", "ditto -c -k --keepParent", "shasum -a 256", "QuietSafariAdHoc.entitlements"):
        if needle not in build:
            fail(f"release script missing {needle}")


def check_identifiers() -> None:
    xcconfig = (ROOT / "Config" / "Shared.xcconfig").read_text(encoding="utf-8")
    if "QUIETSAFARI_BUNDLE_PREFIX = com.quietsafari.macos" not in xcconfig:
        fail("bundle prefix drifted")
    if "QUIETSAFARI_PRIVACY_BUNDLE_ID" not in xcconfig:
        fail("privacy bundle id is missing from the xcconfig")
    if "QUIETSAFARI_RUSSIAN_BUNDLE_ID" not in xcconfig:
        fail("russian bundle id is missing from the xcconfig")
    swift = (ROOT / "App" / "SettingsStore.swift").read_text(encoding="utf-8")
    for needle in (
        'defaultWebExtensionBundleID = "com.quietsafari.macos.extension"',
        'defaultContentBlockerBundleID = "com.quietsafari.macos.content-blocker"',
    ):
        if needle not in swift:
            fail(f"fallback bundle id missing: {needle}")
    page = (ROOT / "App" / "TestPage.html").read_text(encoding="utf-8")
    for needle in ("adsbygoogle", "google_ads_iframe_1", "div-gpt-ad-banner", "This paragraph should stay visible"):
        if needle not in page:
            fail(f"test page missing {needle}")


def check_generated() -> None:
    for script in ("generate_icons.py", "generate_xcodeproj.py"):
        result = subprocess.run([sys.executable, str(ROOT / "scripts" / script), "--check"], cwd=ROOT, text=True, capture_output=True)
        if result.returncode != 0:
            fail(result.stdout + result.stderr)
    scheme = (ROOT / "QuietSafari.xcodeproj" / "xcshareddata" / "xcschemes" / "QuietSafari.xcscheme").read_text(encoding="utf-8")
    ET.fromstring(scheme)
    ET.fromstring((ROOT / "QuietSafari.xcodeproj" / "project.xcworkspace" / "contents.xcworkspacedata").read_text(encoding="utf-8"))
    pbx = (ROOT / "QuietSafari.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
    if pbx.count("{") != pbx.count("}"):
        fail("pbxproj braces are unbalanced")
    if "DEVELOPMENT_TEAM =" in pbx:
        fail("a team id was committed")
    for needle in ("QuietSafariExtension", "QuietSafariContentBlocker", "QuietSafariRussian", "com.apple.product-type.app-extension", "Embed Foundation Extensions"):
        if needle not in pbx:
            fail(f"pbxproj missing {needle}")


def check_javascript() -> None:
    node = subprocess.run(["node", "--version"], capture_output=True, text=True)
    if node.returncode != 0:
        print("node is not installed; skipped JS syntax check")
        return
    for path in (ROOT / "Extension" / "Resources").glob("*.js"):
        result = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"{path.name} failed node --check\n{result.stderr}")


def main() -> None:
    check_normalizer()
    check_rules()
    check_manifest()
    check_plists()
    check_identifiers()
    check_generated()
    check_javascript()
    print("QuietSafari scaffold checks passed")


if __name__ == "__main__":
    main()
