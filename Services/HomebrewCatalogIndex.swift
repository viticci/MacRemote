import Foundation

/// Derived, read-only index of Homebrew's local API caches (spec §2.5):
/// formula/cask descriptions and the executable→formula reverse map. Parsed
/// from files already on disk — the JWS signature is deliberately not
/// verified because the strings are advisory display metadata, sanitized and
/// never executed (§4.4). Rebuilt only when the cache files' mtimes move.
struct HomebrewCatalogIndex: Sendable {
    struct FormulaEntry: Equatable, Sendable {
        let name: String
        let desc: String?
        let homepage: String?
        let license: String?
        let aliases: [String]
        let executables: [String]
    }

    struct CaskEntry: Equatable, Sendable {
        let token: String
        let displayName: String?
        let desc: String?
        let homepage: String?
        let version: String?
        let binaryNames: [String]
    }

    static let maximumCatalogBytes = 64 * 1024 * 1024   // DL-15

    let formulaeByName: [String: FormulaEntry]   // includes alias keys
    let casksByToken: [String: CaskEntry]
    let formulaByExecutable: [String: String]

    static let empty = HomebrewCatalogIndex(formulaeByName: [:], casksByToken: [:], formulaByExecutable: [:])

    init(
        formulaeByName: [String: FormulaEntry],
        casksByToken: [String: CaskEntry],
        formulaByExecutable: [String: String]
    ) {
        self.formulaeByName = formulaeByName
        self.casksByToken = casksByToken
        self.formulaByExecutable = formulaByExecutable
    }

    func entry(forFormula name: String) -> FormulaEntry? {
        formulaeByName[name]
    }

    func entry(forCask token: String) -> CaskEntry? {
        casksByToken[token]
    }

    func formulaName(forExecutable executable: String) -> String? {
        formulaByExecutable[executable]
    }

    // MARK: Loading (mtime-cached)

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries = [String: (fingerprint: String, index: HomebrewCatalogIndex)]()

        func index(for key: String, fingerprint: String, build: () -> HomebrewCatalogIndex) -> HomebrewCatalogIndex {
            lock.lock()
            defer { lock.unlock() }
            if let cached = entries[key], cached.fingerprint == fingerprint {
                return cached.index
            }
            let index = build()
            entries[key] = (fingerprint, index)
            return index
        }
    }

    private static let cache = Cache()

    /// Loads (or reuses) the derived index for a Homebrew API cache directory,
    /// e.g. `~/Library/Caches/Homebrew/api`.
    static func load(apiCacheDirectory: String, fileReader: any FileReading) -> HomebrewCatalogIndex {
        let formulaPath = apiCacheDirectory + "/formula.jws.json"
        let caskPath = apiCacheDirectory + "/cask.jws.json"
        let executablesPath = apiCacheDirectory + "/internal/executables.txt"
        let fingerprint = [formulaPath, caskPath, executablesPath]
            .map { path -> String in
                guard let attributes = fileReader.attributes(atPath: path) else { return "-" }
                return "\(Int(attributes.modificationDate?.timeIntervalSince1970 ?? 0)):\(attributes.fileSize)"
            }
            .joined(separator: "|")

        return cache.index(for: apiCacheDirectory, fingerprint: fingerprint) {
            build(apiCacheDirectory: apiCacheDirectory, fileReader: fileReader)
        }
    }

    static func build(apiCacheDirectory: String, fileReader: any FileReading) -> HomebrewCatalogIndex {
        var formulae = [String: FormulaEntry]()
        var casks = [String: CaskEntry]()
        var executableMap = [String: String]()

        func mergeFormula(_ entry: FormulaEntry) {
            formulae[entry.name] = entry
            for alias in entry.aliases where formulae[alias] == nil {
                formulae[alias] = entry
            }
            for executable in entry.executables where executableMap[executable] == nil {
                executableMap[executable] = entry.name
            }
        }

        if let data = fileReader.contents(
            atPath: apiCacheDirectory + "/formula.jws.json",
            maxBytes: maximumCatalogBytes
        ), let payload = jwsPayload(from: data) {
            for entry in formulaEntries(fromPayload: payload) {
                mergeFormula(entry)
            }
        }

        if let data = fileReader.contents(
            atPath: apiCacheDirectory + "/cask.jws.json",
            maxBytes: maximumCatalogBytes
        ), let payload = jwsPayload(from: data) {
            for entry in caskEntries(fromPayload: payload) {
                casks[entry.token] = entry
            }
        }

        // HB6 internal dict form fills any gaps.
        if formulae.isEmpty || casks.isEmpty {
            let internalDirectory = apiCacheDirectory + "/internal"
            for name in fileReader.contentsOfDirectory(atPath: internalDirectory)
            where name.hasPrefix("packages.") && name.hasSuffix(".jws.json") {
                guard let data = fileReader.contents(
                    atPath: internalDirectory + "/" + name,
                    maxBytes: maximumCatalogBytes
                ), let payload = jwsPayload(from: data) as? [String: Any] else {
                    continue
                }
                if formulae.isEmpty, let dict = payload["formulae"] as? [String: Any] {
                    for (formulaName, value) in dict {
                        guard let object = value as? [String: Any] else { continue }
                        mergeFormula(formulaEntry(name: formulaName, object: object))
                    }
                }
                if casks.isEmpty, let dict = payload["casks"] as? [String: Any] {
                    for (token, value) in dict {
                        guard let object = value as? [String: Any] else { continue }
                        casks[token] = caskEntry(token: token, object: object)
                    }
                }
            }
        }

        // The O(1) exe→formula reverse map (333 KB text file).
        if let data = fileReader.contents(
            atPath: apiCacheDirectory + "/internal/executables.txt",
            maxBytes: 8 * 1024 * 1024
        ) {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let formula = String(line[..<colon])
                for executable in line[line.index(after: colon)...].split(separator: " ") {
                    let name = String(executable)
                    if executableMap[name] == nil {
                        executableMap[name] = formula
                    }
                }
            }
        }

        return HomebrewCatalogIndex(
            formulaeByName: formulae,
            casksByToken: casks,
            formulaByExecutable: executableMap
        )
    }

    // MARK: JWS + entry parsing

    /// `{"payload": "<JSON string>", …}` → the decoded payload value.
    static func jwsPayload(from data: Data) -> Any? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payloadString = envelope["payload"] as? String,
              let payloadData = payloadString.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: payloadData)
    }

    static func formulaEntries(fromPayload payload: Any) -> [FormulaEntry] {
        guard let array = payload as? [[String: Any]] else { return [] }
        return array.compactMap { object in
            guard let name = object["name"] as? String, !name.isEmpty else { return nil }
            return formulaEntry(name: name, object: object)
        }
    }

    static func formulaEntry(name: String, object: [String: Any]) -> FormulaEntry {
        FormulaEntry(
            name: name,
            desc: object["desc"] as? String,
            homepage: object["homepage"] as? String,
            license: object["license"] as? String,
            aliases: object["aliases"] as? [String] ?? [],
            executables: object["executables"] as? [String] ?? []
        )
    }

    static func caskEntries(fromPayload payload: Any) -> [CaskEntry] {
        guard let array = payload as? [[String: Any]] else { return [] }
        return array.compactMap { object in
            guard let token = object["token"] as? String, !token.isEmpty else { return nil }
            return caskEntry(token: token, object: object)
        }
    }

    static func caskEntry(token: String, object: [String: Any]) -> CaskEntry {
        var binaryNames = [String]()
        for artifact in object["artifacts"] as? [[String: Any]] ?? [] {
            guard let binary = artifact["binary"] as? [Any], let first = binary.first else { continue }
            if let options = binary.compactMap({ $0 as? [String: Any] }).first,
               let target = options["target"] as? String {
                binaryNames.append((target as NSString).lastPathComponent)
            } else if let sourceName = first as? String {
                binaryNames.append((sourceName as NSString).lastPathComponent)
            }
        }
        let names = (object["name"] as? [String]) ?? (object["names"] as? [String]) ?? []
        return CaskEntry(
            token: token,
            displayName: names.first,
            desc: object["desc"] as? String,
            homepage: object["homepage"] as? String,
            version: object["version"] as? String,
            binaryNames: binaryNames
        )
    }
}

/// Parsed `INSTALL_RECEIPT.json` facts (all keys optional across HB 4/5/6
/// receipt generations).
struct HomebrewInstallReceipt: Equatable, Sendable {
    let installedOnRequest: Bool?
    let installedAsDependency: Bool
    let installDate: Date?
    let tap: String?
    let aliases: [String]

    static func parse(_ data: Data) -> HomebrewInstallReceipt? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let source = object["source"] as? [String: Any]
        return HomebrewInstallReceipt(
            installedOnRequest: object["installed_on_request"] as? Bool,
            installedAsDependency: object["installed_as_dependency"] as? Bool ?? false,
            installDate: (object["time"] as? Double).map { Date(timeIntervalSince1970: $0) },
            tap: source?["tap"] as? String,
            aliases: object["aliases"] as? [String] ?? []
        )
    }
}

/// Third-party tap formulas are plain Ruby files; metadata comes from a
/// line-anchored regex — the Ruby is never evaluated (spec §2.5).
enum HomebrewTapFormulaParser {
    static func metadata(from data: Data) -> (desc: String?, homepage: String?) {
        let text = String(decoding: data, as: UTF8.self)
        return (
            desc: firstCapture(#"(?m)^\s*desc\s+"([^"]+)""#, in: text),
            homepage: firstCapture(#"(?m)^\s*homepage\s+"([^"]+)""#, in: text)
        )
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
