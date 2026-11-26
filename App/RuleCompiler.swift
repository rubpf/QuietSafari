import Foundation

/// Turns the bundled proof list plus the current settings into the JSON Safari compiles.
enum RuleCompiler {
    enum CompileError: LocalizedError {
        case unreadable
        case notAnArray

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Could not read the built-in rule list."
            case .notAnArray:
                return "The built-in rule list is damaged."
            }
        }
    }

    static func compile(baseJSON: Data, settings: QuietSafariSettings) throws -> Data {
        let parsed = try JSONSerialization.jsonObject(with: baseJSON)
        guard var rules = parsed as? [[String: Any]] else {
            throw CompileError.notAnArray
        }
        if !settings.blockingEnabled {
            rules = []
        } else {
            for domain in settings.allowlist {
                rules.append([
                    "action": ["type": "ignore-previous-rules"],
                    "trigger": [
                        "if-domain": [domain],
                        "url-filter": ".*",
                    ],
                ])
            }
        }
        guard JSONSerialization.isValidJSONObject(rules) else {
            throw CompileError.unreadable
        }
        return try JSONSerialization.data(withJSONObject: rules)
    }
}

/// Keep the accepted shapes in sync with scripts/validate_project.py.
enum DomainNormalizer {
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("https://") {
            text = String(text.dropFirst("https://".count))
        } else if text.hasPrefix("http://") {
            text = String(text.dropFirst("http://".count))
        }
        if let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<end])
        }
        if let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        if text.hasPrefix("www.") {
            text = String(text.dropFirst("www.".count))
        }
        guard text.count <= 253 else {
            return nil
        }
        if text == "localhost" {
            return text
        }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isValidLabel) else {
            return nil
        }
        return text
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard (1 ... 63).contains(label.count), let first = label.first, let last = label.last else {
            return false
        }
        guard isHostCharacter(first), isHostCharacter(last), first != "-", last != "-" else {
            return false
        }
        return label.allSatisfy { isHostCharacter($0) || $0 == "-" }
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        guard character.isASCII else {
            return false
        }
        return character.isLetter || character.isNumber
    }
}
