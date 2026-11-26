import Foundation

/// Copies, updates, and personalizes the two Safari rule lists.
enum FilterLibrary {
    struct Meta: Codable, Equatable {
        var baseVersion: Int
        var adCount: Int
        var privacyCount: Int
        var updatedAt: String
        var source: String

        static let empty = Meta(baseVersion: 0, adCount: 0, privacyCount: 0, updatedAt: "", source: "")
    }

    enum UpdateError: LocalizedError {
        case download
        case rejected
        case notWritten

        var errorDescription: String? {
            switch self {
            case .download:
                return "Не удалось скачать EasyList или EasyPrivacy. Проверьте интернет и нажмите ещё раз."
            case .rejected:
                return "Новые списки не прошли проверку и не применены. Остался предыдущий набор."
            case .notWritten:
                return "Списки скачались, но записать их в общую папку не получилось."
            }
        }
    }

    private static let adsBase = "base-blockerList.json"
    private static let privacyBase = "base-privacyList.json"
    private static let metaName = "filter-meta.json"

    static func prepare() -> Meta {
        var meta = readMeta()
        let haveBases = QuietSafariShared.readRules(named: adsBase) != nil && QuietSafariShared.readRules(named: privacyBase) != nil
        if meta.baseVersion >= QuietSafariShared.bundledFilterVersion && haveBases {
            return meta
        }
        guard let ads = bundled(QuietSafariShared.rulesFileName),
              let privacy = bundled(QuietSafariShared.privacyRulesFileName) else {
            return meta
        }
        guard QuietSafariShared.writeRules(ads, named: adsBase),
              QuietSafariShared.writeRules(privacy, named: privacyBase) else {
            return meta
        }
        let counts = bundledCounts()
        meta = Meta(
            baseVersion: QuietSafariShared.bundledFilterVersion,
            adCount: counts.ads,
            privacyCount: counts.privacy,
            updatedAt: "",
            source: "bundled"
        )
        writeMeta(meta)
        return meta
    }

    static func apply(settings: QuietSafariSettings) -> Bool {
        guard let ads = QuietSafariShared.readRules(named: adsBase) ?? bundled(QuietSafariShared.rulesFileName),
              let privacy = QuietSafariShared.readRules(named: privacyBase) ?? bundled(QuietSafariShared.privacyRulesFileName) else {
            return false
        }
        guard let servedAds = serve(ads, settings: settings),
              let servedPrivacy = serve(privacy, settings: settings) else {
            return false
        }
        return QuietSafariShared.writeRules(servedAds, named: QuietSafariShared.rulesFileName)
            && QuietSafariShared.writeRules(servedPrivacy, named: QuietSafariShared.privacyRulesFileName)
    }

    static func download(completion: @escaping (Result<Meta, Error>) -> Void) {
        let session = URLSession.shared
        session.dataTask(with: FilterConverter.easyListURL) { adsData, adsResponse, adsError in
            guard adsError == nil, let adsData, httpOK(adsResponse) else {
                DispatchQueue.main.async { completion(.failure(UpdateError.download)) }
                return
            }
            session.dataTask(with: FilterConverter.easyPrivacyURL) { privacyData, privacyResponse, privacyError in
                guard privacyError == nil, let privacyData, httpOK(privacyResponse) else {
                    DispatchQueue.main.async { completion(.failure(UpdateError.download)) }
                    return
                }
                let adsText = String(decoding: adsData, as: UTF8.self)
                let privacyText = String(decoding: privacyData, as: UTF8.self)
                guard let converted = FilterConverter.convert(easyList: adsText, easyPrivacy: privacyText) else {
                    DispatchQueue.main.async { completion(.failure(UpdateError.rejected)) }
                    return
                }
                let wroteAds = QuietSafariShared.writeRules(converted.ads, named: adsBase)
                let wrotePrivacy = QuietSafariShared.writeRules(converted.privacy, named: privacyBase)
                guard wroteAds && wrotePrivacy else {
                    DispatchQueue.main.async { completion(.failure(UpdateError.notWritten)) }
                    return
                }
                let meta = Meta(
                    baseVersion: QuietSafariShared.bundledFilterVersion,
                    adCount: converted.adCount,
                    privacyCount: converted.privacyCount,
                    updatedAt: Self.stamp(),
                    source: "downloaded"
                )
                writeMeta(meta)
                DispatchQueue.main.async { completion(.success(meta)) }
            }.resume()
        }.resume()
    }

    static func summary(_ meta: Meta) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ru_RU")
        let ads = formatter.string(from: NSNumber(value: meta.adCount)) ?? "\(meta.adCount)"
        let privacy = formatter.string(from: NSNumber(value: meta.privacyCount)) ?? "\(meta.privacyCount)"
        if meta.source == "downloaded", !meta.updatedAt.isEmpty {
            return "EasyList: \(ads) · EasyPrivacy: \(privacy). Обновлено \(meta.updatedAt)."
        }
        return "EasyList: \(ads) · EasyPrivacy: \(privacy). Встроенные списки, кнопка выше скачивает свежие."
    }

    private static func serve(_ base: Data, settings: QuietSafariSettings) -> Data? {
        if settings.blockingEnabled && settings.allowlist.isEmpty {
            return base
        }
        return try? RuleCompiler.compile(baseJSON: base, settings: settings)
    }

    private static func bundled(_ name: String) -> Data? {
        let baseName = (name as NSString).deletingPathExtension
        guard let url = Bundle.main.url(forResource: baseName, withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func bundledCounts() -> (ads: Int, privacy: Int) {
        guard let url = Bundle.main.url(forResource: "filter-counts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0)
        }
        let ads = (object["adCount"] as? NSNumber)?.intValue ?? 0
        let privacy = (object["privacyCount"] as? NSNumber)?.intValue ?? 0
        return (ads, privacy)
    }

    private static func readMeta() -> Meta {
        guard let url = QuietSafariShared.containerURL?.appendingPathComponent(metaName),
              let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            return .empty
        }
        return meta
    }

    private static func writeMeta(_ meta: Meta) {
        guard let url = QuietSafariShared.containerURL?.appendingPathComponent(metaName),
              let data = try? JSONEncoder().encode(meta) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func httpOK(_ response: URLResponse?) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}
