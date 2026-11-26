#!/usr/bin/env python3
"""Reject content-blocker JSON that WebKit would refuse to compile.

One bad url-filter fails the whole file (ContentExtensionError::JSONInvalidRegex).
WebKit's URL filter parser allows groups, character classes, and ? * +, and it
allows ".*" as a match-everything pattern. It does not allow disjunctions (|),
backreferences, lazy or counted quantifiers, lookahead, or a ^ / $ that is not
the first / last term. A domain that is not lowercase ASCII fails the file too.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LISTS = ("blockerList.json", "privacyList.json", "russianList.json")
MAX_RULES = 150_000
MAX_BYTES = 7_500_000
ACTIONS = {"block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https"}
RESOURCE_TYPES = {
    "document",
    "image",
    "style-sheet",
    "script",
    "font",
    "raw",
    "svg-document",
    "media",
    "popup",
}
LOAD_TYPES = {"first-party", "third-party"}


def fail(message: str) -> None:
    raise SystemExit(message)


def url_filter_error(pattern: str) -> str | None:
    if not pattern:
        return "empty url-filter"
    if any(ord(char) > 127 for char in pattern):
        return "non-ASCII url-filter"
    index = 0
    in_class = False
    escaped = False
    saw_atom = False
    length = len(pattern)
    while index < length:
        char = pattern[index]
        if escaped:
            if char in {"d", "D", "s", "S", "w", "W", "b", "B"}:
                return f"unsupported class \\{char}"
            if char.isdigit():
                return "backreference"
            escaped = False
            saw_atom = True
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if in_class:
            if char == "]":
                in_class = False
                saw_atom = True
            index += 1
            continue
        if char == "[":
            in_class = True
            index += 1
            if index < length and pattern[index] == "^":
                index += 1
            continue
        if char == "|":
            return "disjunction"
        if char == "^" and index != 0:
            return "start anchor is not the first character"
        if char == "$" and index != length - 1:
            return "end anchor is not the last character"
        if char == "{":
            return "counted quantifier"
        if char == "(":
            if index + 1 < length and pattern[index + 1] == "?":
                return "unsupported group"
            index += 1
            continue
        if char in {"*", "+", "?"}:
            if not saw_atom:
                return "quantifier without an atom"
            saw_atom = False
            index += 1
            continue
        if char == ")":
            saw_atom = True
            index += 1
            continue
        saw_atom = True
        index += 1
    if in_class or escaped:
        return "truncated pattern"
    return None


def domain_error(domain: str) -> str | None:
    if not domain:
        return "empty domain"
    if any(ord(char) > 127 or char.isupper() for char in domain):
        return "domain is not lowercase ASCII"
    if any(char in domain for char in " /"):
        return "domain contains a space or slash"
    return None


def check_file(path: Path) -> None:
    raw = path.read_bytes()
    if len(raw) > MAX_BYTES:
        fail(f"{path.name} is {len(raw)} bytes, over {MAX_BYTES}")
    try:
        rules = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"{path.name} is not JSON: {error}")
    if not isinstance(rules, list):
        fail(f"{path.name} is not a rule array")
    if not rules:
        fail(f"{path.name} has no rules")
    if len(rules) > MAX_RULES:
        fail(f"{path.name} has {len(rules)} rules, over {MAX_RULES}")
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict):
            fail(f"{path.name} rule {index} is not an object")
        trigger = rule.get("trigger")
        action = rule.get("action")
        if not isinstance(trigger, dict) or not isinstance(action, dict):
            fail(f"{path.name} rule {index} is missing trigger or action")
        if "if-domain" in trigger and "unless-domain" in trigger:
            fail(f"{path.name} rule {index} mixes if-domain and unless-domain")
        pattern = trigger.get("url-filter")
        if not isinstance(pattern, str):
            fail(f"{path.name} rule {index} has no url-filter")
        problem = url_filter_error(pattern)
        if problem:
            fail(f"{path.name} rule {index} {problem}: {pattern[:180]}")
        action_type = action.get("type")
        if action_type not in ACTIONS:
            fail(f"{path.name} rule {index} has action {action_type!r}")
        if action_type == "block" and pattern == ".*":
            fail(f"{path.name} rule {index} blocks every URL")
        if action_type == "css-display-none" and not action.get("selector"):
            fail(f"{path.name} rule {index} hides with an empty selector")
        for key in ("if-domain", "unless-domain"):
            domains = trigger.get(key)
            if domains is None:
                continue
            if not isinstance(domains, list) or not domains:
                fail(f"{path.name} rule {index} has an empty {key}")
            for domain in domains:
                if not isinstance(domain, str) or domain_error(domain):
                    fail(f"{path.name} rule {index} bad {key} {domain!r}")
        resources = trigger.get("resource-type")
        if resources is not None:
            if not isinstance(resources, list) or any(item not in RESOURCE_TYPES for item in resources):
                fail(f"{path.name} rule {index} has a bad resource-type")
        loads = trigger.get("load-type")
        if loads is not None:
            if not isinstance(loads, list) or any(item not in LOAD_TYPES for item in loads):
                fail(f"{path.name} rule {index} has a bad load-type")
    print(f"{path.name}: {len(rules)} rules, WebKit url-filter check passed")


def self_test() -> None:
    if url_filter_error("^https?://([^/?#]*\\.)?doubleclick\\.net[^A-Za-z0-9_%.-]") is not None:
        fail("the separator pattern was rejected")
    if url_filter_error("([^A-Za-z0-9_%.-]|$)") is None:
        fail("a disjunction was accepted")
    if url_filter_error(".*") is not None:
        fail("match-everything was rejected")


def main() -> None:
    self_test()
    for name in LISTS:
        check_file(ROOT / "Shared" / name)


if __name__ == "__main__":
    main()
