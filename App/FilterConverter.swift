import Foundation

/// EasyList / EasyPrivacy → Safari content-blocker JSON.
/// Same rules as scripts/convert_filters.py. One bad or oversized rule is dropped
/// instead of being written: Safari rejects the whole file when a single rule is invalid.
enum FilterConverter {
    static let easyListURL = URL(string: "https://easylist.to/easylist/easylist.txt")!
    static let easyPrivacyURL = URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
    static let ruAdListURL = URL(string: "https://easylist-downloads.adblockplus.org/advblock.txt")!
    static let maxRules = 140_000
    static let maxBytes = 7_200_000

    struct Converted {
        var ads: Data
        var privacy: Data
        var russian: Data
        var adCount: Int
        var privacyCount: Int
        var russianCount: Int
    }

    static func convert(easyList: String, easyPrivacy: String, russian: String) -> Converted? {
        let adsRules = FilterPieces.fit(FilterPieces.convertText(easyList))
        var privacyRules = FilterPieces.fit(FilterPieces.convertText(easyPrivacy))
        var russianRules = FilterPieces.fit(FilterPieces.convertText(russian))
        privacyRules.append(contentsOf: FilterPieces.yandexPrivacyRules())
        russianRules.append(contentsOf: FilterPieces.yandexAdRules())
        guard adsRules.count > 10_000, privacyRules.count > 10_000, russianRules.count > 5_000 else {
            return nil
        }
        guard safe(adsRules), safe(privacyRules), safe(russianRules) else {
            return nil
        }
        guard let ads = encode(adsRules), let privacy = encode(privacyRules), let russianData = encode(russianRules) else {
            return nil
        }
        guard ads.count <= maxBytes + 8192, privacy.count <= maxBytes + 8192, russianData.count <= maxBytes else {
            return nil
        }
        return Converted(
            ads: ads,
            privacy: privacy,
            russian: russianData,
            adCount: adsRules.count,
            privacyCount: privacyRules.count,
            russianCount: russianRules.count
        )
    }

    private static func encode(_ rules: [[String: Any]]) -> Data? {
        guard JSONSerialization.isValidJSONObject(rules) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: rules)
    }

    private static func safe(_ rules: [[String: Any]]) -> Bool {
        let protected = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/",
            "https://rr1---sn-xxxx.googlevideo.com/videoplayback?id=1",
            "https://www.google.com/",
            "https://yandex.ru/",
            "https://ya.ru/",
            "https://yandex.ru/maps/213/moscow/",
            "https://yastatic.net/s3/home-static/logo.png",
        ]
        for rule in rules {
            guard (rule["action"] as? [String: Any])?["type"] as? String == "block",
                  let pattern = (rule["trigger"] as? [String: Any])?["url-filter"] as? String
            else {
                continue
            }
            if pattern == ".*" {
                return false
            }
            let interesting = pattern.contains("youtube") || pattern.contains("googlevideo") || pattern.contains("ytimg") || pattern.contains("google.com") || pattern.contains("yandex") || pattern.contains("yastatic")
            guard interesting, let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for url in protected {
                let range = NSRange(url.startIndex..., in: url)
                if expression.firstMatch(in: url, options: [], range: range) != nil {
                    return false
                }
            }
        }
        return true
    }
}

private enum FilterPieces {
    static let resourceTypes = [
        "script": "script",
        "image": "image",
        "stylesheet": "style-sheet",
        "font": "font",
        "media": "media",
        "xmlhttprequest": "raw",
        "popup": "popup",
        "document": "document",
    ]
    static let loadTypes = [
        "third-party": "third-party",
        "3p": "third-party",
        "first-party": "first-party",
        "1p": "first-party",
    ]
    static let bareOptions: Set<String> = ["subdocument", "frame", "important"]
    static let allTypes = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]
    static let unsafeSelector = try? NSRegularExpression(
        pattern: ":has\\(|:has-text|:xpath|:matches-css|:upward|:remove\\(|:style\\(|:-abp|\\\\|\\{|\\}|/|>>",
        options: [.caseInsensitive]
    )

    struct Options {
        var types: [String] = []
        var load: String?
        var domainsIf: [String] = []
        var domainsUnless: [String] = []
        var matchCase = false
    }

    static func convertText(_ text: String) -> (blocks: [[String: Any]], cosmetics: [[String: Any]], exceptions: [[String: Any]]) {
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        let cosmetics = CosmeticBook()
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[") {
                return
            }
            if let parts = splitOnce(trimmed, "#@#") {
                cosmetics.add(domains: parts.0, selector: parts.1, exception: true)
                return
            }
            if trimmed.contains("#?#") || trimmed.contains("#$#") || trimmed.contains("#%#") {
                return
            }
            if let parts = splitOnce(trimmed, "##") {
                if parts.0.contains("://") {
                    return
                }
                cosmetics.add(domains: parts.0, selector: parts.1, exception: false)
                return
            }
            guard let rule = networkRule(trimmed) else {
                return
            }
            if (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" {
                exceptions.append(rule)
            } else {
                blocks.append(rule)
            }
        }
        return (blocks, cosmetics.rules(), exceptions)
    }

    static func fit(_ parts: (blocks: [[String: Any]], cosmetics: [[String: Any]], exceptions: [[String: Any]])) -> [[String: Any]] {
        let blocks = parts.blocks.filter { !isProtected($0) }
        let exceptions = parts.exceptions
        let base = blocks + exceptions
        guard base.count <= FilterConverter.maxRules, encodedSize(base) <= FilterConverter.maxBytes else {
            return []
        }
        var kept: [[String: Any]] = []
        var size = encodedSize(base)
        var room = FilterConverter.maxRules - base.count
        let ranked = parts.cosmetics.sorted { lhs, rhs in
            rank(lhs) < rank(rhs)
        }
        for rule in ranked {
            if room <= 0 {
                break
            }
            let extra = encodedSize([rule]) + 1
            if size + extra > FilterConverter.maxBytes {
                continue
            }
            kept.append(rule)
            size += extra
            room -= 1
        }
        return blocks + kept + exceptions
    }

    static func rank(_ rule: [String: Any]) -> String {
        let selector = (rule["action"] as? [String: Any])?["selector"] as? String ?? ""
        let hot = selector.contains("ytd-") || selector.contains("ytp-ad") || selector.contains("adsbygoogle") || selector.contains("google_ads") || selector.contains("masthead")
        return (hot ? "0" : "1") + selector
    }

    static func encodedSize(_ rules: [[String: Any]]) -> Int {
        (try? JSONSerialization.data(withJSONObject: rules).count) ?? Int.max
    }

    static func isProtected(_ rule: [String: Any]) -> Bool {
        guard (rule["action"] as? [String: Any])?["type"] as? String == "block",
              let pattern = (rule["trigger"] as? [String: Any])?["url-filter"] as? String
        else {
            return false
        }
        if pattern == ".*" {
            return true
        }
        let interesting = pattern.contains("youtube") || pattern.contains("googlevideo") || pattern.contains("ytimg") || pattern.contains("gstatic") || pattern.contains("googleapis") || pattern.contains("google.com")
        guard interesting, let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return interesting && pattern.contains("youtube")
        }
        let urls = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/",
            "https://youtube.com/",
            "https://rr1---sn-xxxx.googlevideo.com/videoplayback?id=1",
            "https://i.ytimg.com/vi/abcdef/hqdefault.jpg",
            "https://www.google.com/",
            "https://fonts.googleapis.com/css?family=Inter",
            "https://www.gstatic.com/images/branding.png",
        ]
        return urls.contains { url in
            expression.firstMatch(in: url, options: [], range: NSRange(url.startIndex..., in: url)) != nil
        }
    }

    static func hostBlock(_ host: String) -> [String: Any] {
        let pattern = abpToRegex("||\(host)^") ?? "^\(host)$"
        return ["action": ["type": "block"], "trigger": ["url-filter": pattern]]
    }

    static func pathBlock(_ host: String, _ path: String) -> [String: Any] {
        let escaped = host.replacingOccurrences(of: ".", with: "\\.")
        return [
            "action": ["type": "block"],
            "trigger": ["url-filter": "^https?://([^/?#]*\\.)?\(escaped)\(path)"],
        ]
    }

    static func yandexAdRules() -> [[String: Any]] {
        var rules: [[String: Any]] = ["an.yandex.ru", "yabs.yandex.ru", "adfox.yandex.ru", "ads.adfox.ru", "yandexadexchange.net"].map(hostBlock)
        rules.append(pathBlock("yandex.ru", "/ads/"))
        rules.append(pathBlock("yandex.ru", "/an/"))
        rules.append(pathBlock("yandex.com", "/ads/"))
        rules.append(pathBlock("yastatic.net", "/partner-code"))
        rules.append(pathBlock("yastatic.net", "/pcode/"))
        rules.append(pathBlock("yastatic.net", "/safeframe-bundles/"))
        let selectors = [
            "div[id^=\"yandex_rtb\"]",
            "div[class^=\"yandex_rtb\"]",
            "div[id^=\"adfox_\"]",
            ".yandex-rtb",
            ".yandex-rtb-block",
            "iframe[src*=\"an.yandex.ru\"]",
            "iframe[src*=\"yandex.ru/ads\"]",
            "iframe[src*=\"adfox.yandex\"]",
        ]
        for selector in selectors {
            rules.append(["action": ["selector": selector, "type": "css-display-none"], "trigger": ["url-filter": ".*"]])
        }
        return rules.filter { !isProtected($0) }
    }

    static func yandexPrivacyRules() -> [[String: Any]] {
        ["mc.yandex.ru", "mc.yandex.com", "mc.yandex.by", "mc.yandex.kz"].map(hostBlock).filter { !isProtected($0) }
    }

    static func networkRule(_ line: String) -> [String: Any]? {
        let exception = line.hasPrefix("@@")
        let body = exception ? String(line.dropFirst(2)) : line
        let pieces = splitOnce(body, "$")
        let pattern = (pieces?.0 ?? body).trimmingCharacters(in: .whitespaces)
        let options = pieces == nil ? Options() : parseOptions(pieces?.1 ?? "")
        guard let options, let filter = abpToRegex(pattern) else {
            return nil
        }
        return [
            "action": ["type": exception ? "ignore-previous-rules" : "block"],
            "trigger": trigger(filter, options),
        ]
    }

    static func abpToRegex(_ pattern: String) -> String? {
        if pattern.count < 2 {
            return nil
        }
        if pattern.hasPrefix("/"), pattern.hasSuffix("/"), pattern.count > 2 {
            return nil
        }
        var text = pattern
        var anchoredDomain = false
        var anchoredStart = false
        var anchoredEnd = false
        if text.hasPrefix("||") {
            anchoredDomain = true
            text = String(text.dropFirst(2))
        } else if text.hasPrefix("|") {
            anchoredStart = true
            text = String(text.dropFirst(1))
        }
        if text.hasSuffix("|") {
            anchoredEnd = true
            text = String(text.dropLast(1))
        }
        if text.isEmpty || text == "*" {
            return nil
        }
        var body = ""
        var wildcards = 0
        for character in text {
            if character == "*" {
                body += ".*"
                wildcards += 1
            } else if character == "^" {
                // WebKit rejects "|" in url-filter. Match a separator character instead.
                body += "[^A-Za-z0-9_%.-]"
            } else if character == "$" {
                return nil
            } else if ".+?()[]{}|\\".contains(character) {
                body += "\\"
                body.append(character)
            } else {
                body.append(character)
            }
        }
        if body.count > 2000 || wildcards > 6 {
            return nil
        }
        if anchoredDomain {
            body = "^https?://([^/?#]*\\.)?" + body
        } else if anchoredStart {
            body = "^" + body
        }
        if anchoredEnd {
            body += "$"
        }
        return body
    }

    static func parseOptions(_ raw: String) -> Options? {
        var options = Options()
        var positive: [String] = []
        var negative: [String] = []
        var sawDomain = false
        for piece in raw.split(separator: ",") {
            let token = piece.trimmingCharacters(in: .whitespaces)
            if token.isEmpty {
                continue
            }
            let halves = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            var name = String(halves[0])
            let value = halves.count > 1 ? String(halves[1]) : ""
            let negated = name.hasPrefix("~")
            if negated {
                name = String(name.dropFirst())
            }
            name = name.lowercased()
            if name == "domain" {
                sawDomain = true
                for domain in value.split(separator: "|") {
                    var text = domain.trimmingCharacters(in: .whitespaces).lowercased()
                    let domainNegated = text.hasPrefix("~")
                    if domainNegated {
                        text = String(text.dropFirst())
                    }
                    let normalized = normalizeDomain(text)
                    guard !normalized.isEmpty else {
                        continue
                    }
                    if domainNegated {
                        options.domainsUnless.append(normalized)
                    } else {
                        options.domainsIf.append(normalized)
                    }
                }
                continue
            }
            if let mapped = resourceTypes[name] {
                (negated ? { negative.append(mapped) } : { positive.append(mapped) })()
                continue
            }
            if let mapped = loadTypes[name] {
                if negated {
                    return nil
                }
                options.load = mapped
                continue
            }
            if name == "match-case" {
                options.matchCase = true
                continue
            }
            if bareOptions.contains(name) {
                continue
            }
            return nil
        }
        if !positive.isEmpty && !negative.isEmpty {
            return nil
        }
        if !negative.isEmpty {
            options.types = allTypes.filter { !negative.contains($0) }
            if options.types.isEmpty {
                return nil
            }
        } else {
            options.types = positive
        }
        if !options.domainsIf.isEmpty && !options.domainsUnless.isEmpty {
            return nil
        }
        if sawDomain && options.domainsIf.isEmpty && options.domainsUnless.isEmpty {
            return nil
        }
        return options
    }

    static func normalizeDomain(_ domain: String) -> String {
        var text = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("*.") {
            text = String(text.dropFirst(2))
        }
        if text.hasPrefix("www.") {
            text = String(text.dropFirst(4))
        }
        if text.isEmpty || text.contains(" ") || text.contains("/") || text.contains("*") {
            return ""
        }
        if text.unicodeScalars.contains(where: { $0.value > 127 }) {
            return ""
        }
        return text
    }

    static func trigger(_ filter: String, _ options: Options) -> [String: Any] {
        var body: [String: Any] = ["url-filter": filter]
        if !options.types.isEmpty {
            body["resource-type"] = options.types
        }
        if let load = options.load {
            body["load-type"] = [load]
        }
        if !options.domainsIf.isEmpty {
            body["if-domain"] = Array(options.domainsIf.prefix(1000))
        }
        if !options.domainsUnless.isEmpty {
            body["unless-domain"] = Array(options.domainsUnless.prefix(200))
        }
        if options.matchCase {
            body["url-filter-is-case-sensitive"] = true
        }
        return body
    }

    static func selectorOK(_ selector: String) -> Bool {
        let text = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.count > 400 || ["*", "body", "html", "video", "#movie_player"].contains(text) {
            return false
        }
        guard let unsafeSelector else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return unsafeSelector.firstMatch(in: text, options: [], range: range) == nil
    }

    static func splitOnce(_ text: String, _ separator: String) -> (String, String)? {
        guard let range = text.range(of: separator) else {
            return nil
        }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
}

private final class CosmeticBook {
    var globalSelectors = Set<String>()
    var excluded: [String: Set<String>] = [:]
    var included: [String: Set<String>] = [:]
    var dropped = Set<String>()

    func add(domains: String, selector: String, exception: Bool) {
        guard FilterPieces.selectorOK(selector) else {
            return
        }
        if exception && domains.isEmpty {
            dropped.insert(selector)
            return
        }
        guard let parsed = cosmeticDomains(domains) else {
            return
        }
        if exception {
            excluded[selector, default: []].formUnion(parsed.include)
            excluded[selector, default: []].formUnion(parsed.exclude)
            return
        }
        if parsed.global {
            globalSelectors.insert(selector)
            excluded[selector, default: []].formUnion(parsed.exclude)
            return
        }
        included[selector, default: []].formUnion(parsed.include)
    }

    func rules() -> [[String: Any]] {
        var compiled: [[String: Any]] = []
        let selectors = globalSelectors.union(included.keys).union(excluded.keys).subtracting(dropped)
        for selector in selectors.sorted() {
            let exclude = excluded[selector] ?? []
            if globalSelectors.contains(selector) {
                if exclude.count > 200 {
                    continue
                }
                var trigger: [String: Any] = ["url-filter": ".*"]
                if !exclude.isEmpty {
                    trigger["unless-domain"] = exclude.sorted()
                }
                compiled.append(["action": ["type": "css-display-none", "selector": selector], "trigger": trigger])
                continue
            }
            let include = (included[selector] ?? []).subtracting(exclude).sorted()
            if include.isEmpty {
                continue
            }
            var start = 0
            while start < include.count {
                let end = min(start + 800, include.count)
                let chunk = Array(include[start..<end])
                compiled.append([
                    "action": ["type": "css-display-none", "selector": selector],
                    "trigger": ["url-filter": ".*", "if-domain": chunk],
                ])
                start = end
            }
        }
        return compiled
    }

    private func cosmeticDomains(_ raw: String) -> (global: Bool, include: [String], exclude: [String])? {
        if raw.isEmpty {
            return (true, [], [])
        }
        var include: [String] = []
        var exclude: [String] = []
        for part in raw.split(separator: ",") {
            var text = part.trimmingCharacters(in: .whitespaces).lowercased()
            if text.isEmpty {
                continue
            }
            let negated = text.hasPrefix("~")
            if negated {
                text = String(text.dropFirst())
            }
            let domain = FilterPieces.normalizeDomain(text)
            if domain.isEmpty {
                return nil
            }
            if negated {
                exclude.append(domain)
            } else {
                include.append(domain)
            }
        }
        if include.isEmpty && !exclude.isEmpty {
            return (true, [], exclude)
        }
        if !include.isEmpty && !exclude.isEmpty {
            let excludedSet = Set(exclude)
            include.removeAll { excludedSet.contains($0) }
            if include.isEmpty {
                return nil
            }
            return (false, include, [])
        }
        return (false, include, [])
    }
}
