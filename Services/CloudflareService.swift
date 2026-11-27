import CryptoKit
import Foundation

struct CloudflareZone: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let accountID: String
    let accountName: String
}

struct CloudflareCustomDomainDeployment: Equatable, Sendable {
    let zone: CloudflareZone
    let hostname: String
    let tunnelID: String
    let tunnelName: String
    let tunnelToken: String
    /// The port of MacRemote's local server that Cloudflare's copy of the
    /// tunnel's settings sends requests to.
    let localPort: Int?

    var publicURL: URL {
        URL(string: "https://\(hostname)")!
    }
}

struct CloudflareCustomDomainDraft: Equatable, Sendable {
    var selectedZoneID: String?
    var subdomain: String = ""
    var apiToken: String = ""

    var trimmedAPIToken: String {
        apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Truthful progress boundaries for a custom-domain deployment. The service
/// emits these in order immediately before it starts each phase.
enum CloudflareDeployStage: Int, CaseIterable, Equatable, Sendable {
    case checkAccess
    case createTunnel
    case configureDNS
    case start

    var detail: String {
        switch self {
        case .checkAccess: "Checking your Cloudflare credentials and existing resources."
        case .createTunnel: "Creating or updating the Cloudflare tunnel."
        case .configureDNS: "Configuring DNS for your public address."
        case .start: "Preparing to start your public link."
        }
    }
}

enum CloudflareServiceError: LocalizedError, Equatable {
    case wranglerUnavailable
    case cloudflaredUnavailable
    case wranglerNotAuthenticated
    case invalidSubdomain
    case zoneRequired
    case existingDNSRecord(String)
    case unownedTunnel(String)
    case savedTunnelChanged(String)
    case insufficientPermissions(String)
    case missingAPIResult
    case api(String)

    static let apiTokenPermissions = "Account Cloudflare Tunnel Edit; and for the selected zone: Zone Read, DNS Edit, and Config Rules Edit"

    var errorDescription: String? {
        switch self {
        case .wranglerUnavailable:
            "MacRemote couldn't find Wrangler on this Mac. Install it, or paste a Cloudflare API token instead."
        case .cloudflaredUnavailable:
            "Cloudflare's helper isn't installed yet. Install it from Connection ▸ Address."
        case .wranglerNotAuthenticated:
            "Wrangler is signed out. Paste an API token, or sign in to Wrangler and choose Load Domains again."
        case .invalidSubdomain:
            "Enter a valid subdomain, such as `macremote` or `macremote-home`."
        case .zoneRequired:
            "Select a Cloudflare domain first."
        case .existingDNSRecord(let hostname):
            "A non-MacRemote DNS record already exists for \(hostname)."
        case .unownedTunnel(let tunnelName):
            "A Cloudflare Tunnel named \(tunnelName) already exists, but MacRemote cannot prove that it owns that tunnel. Rename it or choose another subdomain."
        case .savedTunnelChanged(let hostname):
            "The saved public link for \(hostname) no longer matches Cloudflare. Nothing was changed. Check the Cloudflare tunnel, or choose a different subdomain."
        case .insufficientPermissions(let operation):
            "Cloudflare rejected the credentials while trying to \(operation). Required permissions: \(Self.apiTokenPermissions)."
        case .missingAPIResult:
            "Cloudflare returned a successful response without the expected result."
        case .api(let message):
            message
        }
    }
}

struct CloudflareService: Sendable {
    private let session: URLSession
    private let runner: any ProcessRunning
    private let executablePath: @Sendable (String) -> String?

    init(
        session: URLSession = .shared,
        runner: any ProcessRunning = ProcessRunner(allowsStdoutSpooling: false),
        executablePath: @escaping @Sendable (String) -> String? = { ExecutableLocator.executablePath(named: $0) }
    ) {
        self.session = session
        self.runner = runner
        self.executablePath = executablePath
    }

    func wranglerPath() -> String? {
        executablePath("wrangler")
    }

    func cloudflaredPath() -> String? {
        executablePath("cloudflared")
    }

    static func canLoadZones(apiToken: String?, wranglerPath: String?) -> Bool {
        hasToken(apiToken) || wranglerPath != nil
    }

    func loadZones(apiToken: String? = nil) async throws -> [CloudflareZone] {
        let apiToken = try await resolvedToken(apiToken)
        let zones: [CloudflareZoneDTO] = try await requestAllPages(
            path: "/zones",
            apiToken: apiToken,
            operation: "list Cloudflare zones",
            queryItems: [URLQueryItem(name: "status", value: "active")]
        )
        return zones.map { $0.zone }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func deployCustomDomain(
        zone: CloudflareZone,
        subdomain: String,
        localServerURL: URL,
        apiToken: String? = nil,
        expectedTunnelID: String? = nil,
        progress: @escaping @Sendable (CloudflareDeployStage) async -> Void = { _ in }
    ) async throws -> CloudflareCustomDomainDeployment {
        guard cloudflaredPath() != nil else {
            await progress(.start)
            throw CloudflareServiceError.cloudflaredUnavailable
        }
        await progress(.checkAccess)
        let apiToken = try await resolvedToken(apiToken)

        let hostname = try Self.hostname(subdomain: subdomain, zoneName: zone.name)
        let tunnelName = Self.tunnelName(hostname: hostname)
        let preflightTunnel = try await existingTunnel(
            named: tunnelName,
            accountID: zone.accountID,
            apiToken: apiToken
        )
        // Resuming an address must not adopt a replacement or another Mac's
        // tunnel, even if its name and DNS otherwise look MacRemote-owned.
        if let expectedTunnelID, preflightTunnel?.id != expectedTunnelID {
            throw CloudflareServiceError.savedTunnelChanged(hostname)
        }
        let preflightDNSRecords = try await existingDNSRecords(
            zoneID: zone.id,
            hostname: hostname,
            apiToken: apiToken
        )
        guard preflightDNSRecords.count <= 1 else {
            throw CloudflareServiceError.existingDNSRecord(hostname)
        }
        let preflightDNSRecord = preflightDNSRecords.first
        if let preflightDNSRecord,
           !Self.dnsRecordIsOwnedByMacRemote(
               type: preflightDNSRecord.type,
               content: preflightDNSRecord.content,
               comment: preflightDNSRecord.comment,
               existingTunnelID: preflightTunnel?.id
           ) {
            throw CloudflareServiceError.existingDNSRecord(hostname)
        }
        if let preflightTunnel {
            guard preflightTunnel.configSrc?.caseInsensitiveCompare("cloudflare") == .orderedSame else {
                throw CloudflareServiceError.unownedTunnel(tunnelName)
            }
            let dnsProvesOwnership = preflightDNSRecord.map {
                Self.dnsRecordTargetsTunnel(
                    type: $0.type,
                    content: $0.content,
                    tunnelID: preflightTunnel.id
                )
            } ?? false
            if !dnsProvesOwnership {
                let configurationProvesOwnership = try await tunnelConfigurationContainsHostname(
                    tunnelID: preflightTunnel.id,
                    accountID: zone.accountID,
                    hostname: hostname,
                    apiToken: apiToken
                )
                guard configurationProvesOwnership else {
                    throw CloudflareServiceError.unownedTunnel(tunnelName)
                }
            }
        }

        // This is the write-permission preflight too: a token with Config
        // Rules Read but not Edit fails here before any other resource changes.
        try await ensureBrowserIntegrityCheckDisabled(
            zoneID: zone.id,
            hostname: hostname,
            apiToken: apiToken
        )

        await progress(.createTunnel)
        let tunnel: CloudflareTunnelDTO
        if let preflightTunnel {
            tunnel = preflightTunnel
        } else {
            tunnel = try await createTunnel(named: tunnelName, accountID: zone.accountID, apiToken: apiToken)
        }

        try await putTunnelConfiguration(
            tunnelID: tunnel.id,
            accountID: zone.accountID,
            hostname: hostname,
            localServerURL: localServerURL,
            apiToken: apiToken
        )

        await progress(.configureDNS)
        try await ensureDNSRecord(
            zoneID: zone.id,
            hostname: hostname,
            tunnelID: tunnel.id,
            apiToken: apiToken
        )

        await progress(.start)
        let tunnelToken = try await tunnelRunToken(tunnelID: tunnel.id, accountID: zone.accountID, apiToken: apiToken)
        return CloudflareCustomDomainDeployment(
            zone: zone,
            hostname: hostname,
            tunnelID: tunnel.id,
            tunnelName: tunnelName,
            tunnelToken: tunnelToken,
            localPort: localServerURL.port
        )
    }

    /// The public hostname for a subdomain of a zone. Throws unless it is a
    /// name DNS can hold: a valid subdomain (`isValidSubdomain`) and at most
    /// 253 characters in all. The subdomain is checked as typed, before it is
    /// lowercased, so a look-alike character is refused, not folded to a letter.
    static func hostname(subdomain: String, zoneName: String) throws -> String {
        let trimmed = subdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = "\(trimmed.lowercased()).\(zoneName)"
        guard isValidSubdomain(trimmed), hostname.utf8.count <= 253 else {
            throw CloudflareServiceError.invalidSubdomain
        }
        return hostname
    }

    /// DNS rules for the part of a hostname before the zone: labels separated
    /// by dots, each 1 to 63 characters, made of ASCII letters, digits, and
    /// hyphens, with no hyphen first or last. Accented letters and other
    /// non-ASCII characters are refused because DNS cannot hold them as typed.
    static func isValidSubdomain(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.utf8.count)
                && label.first != "-"
                && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func tunnelName(hostname: String) -> String {
        let suffix = hostname
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
        return "macremote-\(suffix)"
    }

    static func browserIntegrityRuleRef(hostname: String) -> String {
        let digest = SHA256.hash(data: Data(hostname.lowercased().utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "macremote_disable_bic_\(digest)"
    }

    static func browserIntegrityRuleExpression(hostname: String) -> String {
        "http.host eq \"\(hostname.lowercased())\""
    }

    static func dnsRecordIsOwnedByMacRemote(
        type: String,
        content: String,
        comment: String?,
        existingTunnelID: String?
    ) -> Bool {
        guard type.caseInsensitiveCompare("CNAME") == .orderedSame else {
            return false
        }
        if comment == dnsOwnershipComment {
            return true
        }
        guard let existingTunnelID else {
            return false
        }
        return content.caseInsensitiveCompare(tunnelDNSContent(tunnelID: existingTunnelID)) == .orderedSame
    }

    private static func tunnelDNSContent(tunnelID: String) -> String {
        "\(tunnelID).cfargotunnel.com"
    }

    static let dnsOwnershipComment = "MacRemote Cloudflare Tunnel"

    private static func dnsRecordTargetsTunnel(
        type: String,
        content: String,
        tunnelID: String
    ) -> Bool {
        type.caseInsensitiveCompare("CNAME") == .orderedSame
            && content.caseInsensitiveCompare(tunnelDNSContent(tunnelID: tunnelID)) == .orderedSame
    }

    /// Cloudflare's Browser Integrity Check rejects legitimate non-browser MCP
    /// clients, including Python's default urllib user agent, before requests
    /// reach MacRemote. Disable it only for this exact connector hostname. The
    /// Rulesets rule endpoints add or patch our rule without replacing any
    /// unrelated configuration rules in the zone entry-point ruleset.
    func ensureBrowserIntegrityCheckDisabled(
        zoneID: String,
        hostname: String,
        apiToken: String?
    ) async throws {
        let operation = "configure Browser Integrity Check for MacRemote's public hostname"
        let phase = "http_config_settings"
        let phaseRuleset = try await configurationRulesEntrypoint(
            zoneID: zoneID,
            apiToken: apiToken,
            operation: operation
        )

        guard let phaseRuleset else {
            let _: CloudflareAPIResponse<CloudflareRulesetDTO> = try await request(
                method: "POST",
                path: "/zones/\(zoneID)/rulesets",
                apiToken: apiToken,
                operation: operation,
                body: [
                    "name": "MacRemote configuration rules",
                    "description": "Compatibility settings for MacRemote public hostnames.",
                    "kind": "zone",
                    "phase": phase,
                    "rules": [Self.browserIntegrityRuleBody(hostname: hostname)]
                ]
            )
            return
        }

        let expectedRef = Self.browserIntegrityRuleRef(hostname: hostname)
        let rules = phaseRuleset.rules ?? []

        if let index = rules.firstIndex(where: { $0.ref == expectedRef }) {
            let existing = rules[index]
            let isLast = index == rules.indices.last
            guard !Self.browserIntegrityRuleMatches(existing, hostname: hostname) || !isLast else {
                return
            }
            let _: CloudflareAPIResponse<CloudflareRulesetDTO> = try await request(
                method: "PATCH",
                path: "/zones/\(zoneID)/rulesets/\(phaseRuleset.id)/rules/\(existing.id)",
                apiToken: apiToken,
                operation: operation,
                body: Self.browserIntegrityRuleBody(hostname: hostname, moveToEnd: true)
            )
            return
        }

        let _: CloudflareAPIResponse<CloudflareRulesetDTO> = try await request(
            method: "POST",
            path: "/zones/\(zoneID)/rulesets/\(phaseRuleset.id)/rules",
            apiToken: apiToken,
            operation: operation,
            body: Self.browserIntegrityRuleBody(hostname: hostname, moveToEnd: true)
        )
    }

    private func configurationRulesEntrypoint(
        zoneID: String,
        apiToken: String?,
        operation: String
    ) async throws -> CloudflareRulesetDTO? {
        let response: CloudflareAPIResponse<CloudflareRulesetDTO>? = try await requestIfPresent(
            method: "GET",
            path: "/zones/\(zoneID)/rulesets/phases/http_config_settings/entrypoint",
            apiToken: apiToken,
            operation: operation
        )
        return try response?.requiredResult()
    }

    private static func browserIntegrityRuleBody(
        hostname: String,
        moveToEnd: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = [
            "ref": browserIntegrityRuleRef(hostname: hostname),
            "description": "Allow API clients to reach MacRemote on \(hostname.lowercased()).",
            "expression": browserIntegrityRuleExpression(hostname: hostname),
            "action": "set_config",
            "action_parameters": ["bic": false],
            "enabled": true
        ]
        if moveToEnd {
            body["position"] = ["after": ""]
        }
        return body
    }

    private static func browserIntegrityRuleMatches(
        _ rule: CloudflareRulesetRuleDTO,
        hostname: String
    ) -> Bool {
        rule.action == "set_config"
            && rule.expression == browserIntegrityRuleExpression(hostname: hostname)
            && rule.actionParameters?.bic == false
            && rule.enabled != false
    }

    private static func hasToken(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Ask Wrangler to refresh/read its own credential store. Never surface its
    /// stdout/stderr in errors: either stream can contain credential material.
    private func resolvedToken(_ apiToken: String?) async throws -> String {
        if Self.hasToken(apiToken) { return apiToken!.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let wranglerPath = wranglerPath() else {
            throw CloudflareServiceError.wranglerUnavailable
        }
        do {
            let result = try await runner.run(
                executablePath: wranglerPath,
                arguments: ["auth", "token", "--json"],
                timeoutSeconds: 20,
                outputByteLimit: 8 * 1024,
                // Wrangler also copies its output into a debug log file unless
                // told not to. The credential must stay in memory only.
                environment: ExecutableLocator.toolEnvironment
                    .merging(["WRANGLER_WRITE_LOGS": "false"]) { _, new in new },
                standardInput: nil
            )
            guard result.succeeded, !result.truncatedStdout,
                  result.stdoutBytesAreValidUTF8 else {
                throw CloudflareServiceError.wranglerNotAuthenticated
            }
            return try Self.wranglerToken(from: Data(result.stdout.utf8))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudflareServiceError.wranglerNotAuthenticated
        }
    }

    static func wranglerToken(from data: Data) throws -> String {
        struct Credential: Decodable { let type: String; let token: String }
        guard let credential = try? JSONDecoder().decode(Credential.self, from: data),
              ["oauth", "api_token"].contains(credential.type),
              !credential.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudflareServiceError.wranglerNotAuthenticated
        }
        return credential.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func existingDNSRecords(
        zoneID: String,
        hostname: String,
        apiToken: String?
    ) async throws -> [CloudflareDNSRecordDTO] {
        let response: CloudflareAPIResponse<[CloudflareDNSRecordDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zoneID)/dns_records",
            apiToken: apiToken,
            operation: "read DNS records for \(hostname)",
            queryItems: [
                URLQueryItem(name: "name", value: hostname)
            ]
        )
        return try response.requiredResult()
    }

    private func existingTunnel(named name: String, accountID: String, apiToken: String?) async throws -> CloudflareTunnelDTO? {
        let tunnels: [CloudflareTunnelDTO] = try await requestAllPages(
            path: "/accounts/\(accountID)/cfd_tunnel",
            apiToken: apiToken,
            operation: "list Cloudflare Tunnels",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
        return tunnels.first { $0.name == name && $0.deletedAt == nil }
    }

    private func createTunnel(named name: String, accountID: String, apiToken: String?) async throws -> CloudflareTunnelDTO {
        let response: CloudflareAPIResponse<CloudflareTunnelDTO> = try await request(
            method: "POST",
            path: "/accounts/\(accountID)/cfd_tunnel",
            apiToken: apiToken,
            operation: "create a Cloudflare Tunnel",
            body: [
                "name": name,
                "config_src": "cloudflare"
            ]
        )
        return try response.requiredResult()
    }

    private func putTunnelConfiguration(
        tunnelID: String,
        accountID: String,
        hostname: String,
        localServerURL: URL,
        apiToken: String?
    ) async throws {
        let _: CloudflareAPIResponse<CloudflareTunnelConfigurationDTO> = try await request(
            method: "PUT",
            path: "/accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations",
            apiToken: apiToken,
            operation: "configure Cloudflare Tunnel ingress",
            body: [
                "config": [
                    "ingress": [
                        [
                            "hostname": hostname,
                            "service": localServerURL.absoluteString
                        ],
                        [
                            "service": "http_status:404"
                        ]
                    ]
                ]
            ] as [String: Any]
        )
    }

    private func tunnelConfigurationContainsHostname(
        tunnelID: String,
        accountID: String,
        hostname: String,
        apiToken: String?
    ) async throws -> Bool {
        let response: CloudflareAPIResponse<CloudflareTunnelConfigurationDTO> = try await request(
            method: "GET",
            path: "/accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations",
            apiToken: apiToken,
            operation: "verify ownership of Cloudflare Tunnel \(tunnelID)"
        )
        return try response.requiredResult().contains(hostname: hostname)
    }

    private func ensureDNSRecord(
        zoneID: String,
        hostname: String,
        tunnelID: String,
        apiToken: String?
    ) async throws {
        // The early read prevents our Configuration Rule from being written for
        // a foreign hostname. Re-read here so a concurrent DNS change cannot be
        // overwritten using the stale preflight snapshot.
        let currentRecords = try await existingDNSRecords(
            zoneID: zoneID,
            hostname: hostname,
            apiToken: apiToken
        )
        guard currentRecords.count <= 1 else {
            throw CloudflareServiceError.existingDNSRecord(hostname)
        }
        let existingRecord = currentRecords.first
        let target = Self.tunnelDNSContent(tunnelID: tunnelID)
        if let existingRecord {
            guard Self.dnsRecordIsOwnedByMacRemote(
                type: existingRecord.type,
                content: existingRecord.content,
                comment: existingRecord.comment,
                existingTunnelID: tunnelID
            ) else {
                throw CloudflareServiceError.existingDNSRecord(hostname)
            }
            let _: CloudflareAPIResponse<CloudflareDNSRecordDTO> = try await request(
                method: "PATCH",
                path: "/zones/\(zoneID)/dns_records/\(existingRecord.id)",
                apiToken: apiToken,
                operation: "update DNS record for \(hostname)",
                body: dnsRecordBody(hostname: hostname, target: target)
            )
            return
        }

        let _: CloudflareAPIResponse<CloudflareDNSRecordDTO> = try await request(
            method: "POST",
            path: "/zones/\(zoneID)/dns_records",
            apiToken: apiToken,
            operation: "create DNS record for \(hostname)",
            body: dnsRecordBody(hostname: hostname, target: target)
        )
    }

    private func dnsRecordBody(hostname: String, target: String) -> [String: Any] {
        [
            "type": "CNAME",
            "name": hostname,
            "content": target,
            "ttl": 1,
            "proxied": true,
            "comment": Self.dnsOwnershipComment
        ]
    }

    private func tunnelRunToken(tunnelID: String, accountID: String, apiToken: String?) async throws -> String {
        let response: CloudflareAPIResponse<String> = try await request(
            method: "GET",
            path: "/accounts/\(accountID)/cfd_tunnel/\(tunnelID)/token",
            apiToken: apiToken,
            operation: "fetch Cloudflare Tunnel run token"
        )
        return try response.requiredResult()
    }

    /// Items Cloudflare returns in one page of a list.
    private static let listPageSize = 50
    /// Ends a list that never stops. 100 pages hold 5,000 zones or tunnels.
    private static let listPageLimit = 100

    /// Reads every page of a Cloudflare list. One page holds 50 items, so an
    /// account with more zones or tunnels would otherwise never see the rest.
    /// The first request is the one the app has always sent; `page` is added
    /// only when Cloudflare's `result_info` says another page exists.
    private func requestAllPages<Item: Decodable>(
        path: String,
        apiToken: String?,
        operation: String,
        queryItems: [URLQueryItem]
    ) async throws -> [Item] {
        var items: [Item] = []
        for page in 1...Self.listPageLimit {
            let response: CloudflareAPIResponse<[Item]> = try await request(
                method: "GET",
                path: path,
                apiToken: apiToken,
                operation: operation,
                queryItems: [URLQueryItem(name: "per_page", value: String(Self.listPageSize))]
                    + queryItems
                    + (page == 1 ? [] : [URLQueryItem(name: "page", value: String(page))])
            )
            let pageItems = try response.requiredResult()
            items += pageItems
            guard !pageItems.isEmpty,
                  response.resultInfo?.hasPage(after: page, itemsRead: items.count) == true else {
                break
            }
        }
        return items
    }

    private func request<T: Decodable>(
        method: String,
        path: String,
        apiToken: String? = nil,
        operation: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> T {
        let request = try await apiRequest(
            method: method,
            path: path,
            apiToken: apiToken,
            queryItems: queryItems,
            body: body
        )
        let data = try await send(request, operation: operation)
        return try decodeAPIResponse(data)
    }

    private func requestIfPresent<T: Decodable>(
        method: String,
        path: String,
        apiToken: String? = nil,
        operation: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> T? {
        let request = try await apiRequest(
            method: method,
            path: path,
            apiToken: apiToken,
            queryItems: queryItems,
            body: body
        )
        guard let data = try await sendIfPresent(request, operation: operation) else {
            return nil
        }
        return try decodeAPIResponse(data)
    }

    private func apiRequest(
        method: String,
        path: String,
        apiToken: String?,
        queryItems: [URLQueryItem],
        body: [String: Any]?
    ) async throws -> URLRequest {
        let token = try await resolvedToken(apiToken)
        var components = URLComponents(string: "https://api.cloudflare.com/client/v4\(path)")!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.checkedData(withJSONObject: body, options: [])
        }
        return request
    }

    private func decodeAPIResponse<T: Decodable>(_ data: Data) throws -> T {
        let decoded = try JSONDecoder.cloudflare.decode(T.self, from: data)
        if let apiResponse = decoded as? AnyCloudflareAPIResponse, !apiResponse.isSuccess {
            throw CloudflareServiceError.api(apiResponse.errorMessage ?? "Cloudflare API request failed.")
        }
        return decoded
    }

    /// Shared transport + error mapping.
    private func send(_ request: URLRequest, operation: String) async throws -> Data {
        guard let data = try await performRequest(request, operation: operation, returnNilOnNotFound: false) else {
            throw CloudflareServiceError.api("Cloudflare API returned HTTP 404.")
        }
        return data
    }

    private func sendIfPresent(_ request: URLRequest, operation: String) async throws -> Data? {
        try await performRequest(request, operation: operation, returnNilOnNotFound: true)
    }

    private func performRequest(
        _ request: URLRequest,
        operation: String,
        returnNilOnNotFound: Bool
    ) async throws -> Data? {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareServiceError.api("Cloudflare returned a non-HTTP response.")
        }

        if returnNilOnNotFound, httpResponse.statusCode == 404 {
            return nil
        }
        if !(200..<300).contains(httpResponse.statusCode) {
            let message = CloudflareAPIErrorMessage.message(from: data) ??
                "Cloudflare API returned HTTP \(httpResponse.statusCode)."
            if httpResponse.statusCode == 403, Self.isPermissionErrorMessage(message) {
                throw CloudflareServiceError.insufficientPermissions(operation)
            }
            throw CloudflareServiceError.api(message)
        }
        return data
    }

    private static func isPermissionErrorMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["authentication", "unauthorized", "permission", "access denied"]
            .contains { lowered.contains($0) }
    }
}

private struct CloudflareAPIResponse<Result: Decodable>: Decodable, AnyCloudflareAPIResponse {
    let success: Bool
    let errors: [CloudflareAPIMessage]
    let messages: [CloudflareAPIMessage]
    let result: Result?
    let resultInfo: CloudflareResultInfo?

    var isSuccess: Bool { success }
    var errorMessage: String? {
        errors.map(\.message).filter { !$0.isEmpty }.joined(separator: "; ")
    }

    func requiredResult() throws -> Result {
        guard success else {
            throw CloudflareServiceError.api(errorMessage ?? "Cloudflare API request failed.")
        }
        guard let result else {
            throw CloudflareServiceError.missingAPIResult
        }
        return result
    }
}

/// The paging summary Cloudflare attaches to a list. Some lists report the
/// number of pages and others only the number of items, so both are read.
private struct CloudflareResultInfo: Decodable {
    let totalPages: Int?
    let totalCount: Int?

    /// Whether the list continues after `page`, given the items read so far.
    func hasPage(after page: Int, itemsRead: Int) -> Bool {
        if let totalPages { return page < totalPages }
        if let totalCount { return itemsRead < totalCount }
        return false
    }
}

private protocol AnyCloudflareAPIResponse {
    var isSuccess: Bool { get }
    var errorMessage: String? { get }
}

private struct CloudflareAPIMessage: Decodable {
    let message: String
}

private struct CloudflareAPIErrorMessage {
    static func message(from data: Data) -> String? {
        guard let response = try? JSONDecoder.cloudflare.decode(CloudflareAPIResponse<EmptyResult>.self, from: data) else {
            return nil
        }
        return response.errorMessage
    }
}

private struct EmptyResult: Decodable {}

private struct CloudflareZoneDTO: Decodable {
    struct Account: Decodable {
        let id: String
        let name: String
    }

    let id: String
    let name: String
    let account: Account

    var zone: CloudflareZone {
        CloudflareZone(id: id, name: name, accountID: account.id, accountName: account.name)
    }
}

private struct CloudflareTunnelDTO: Decodable {
    let id: String
    let name: String
    let configSrc: String?
    let deletedAt: String?
}

private struct CloudflareTunnelConfigurationDTO: Decodable {
    struct Configuration: Decodable {
        struct Ingress: Decodable {
            let hostname: String?
        }

        let ingress: [Ingress]?
    }

    let config: Configuration?

    func contains(hostname: String) -> Bool {
        config?.ingress?.contains {
            $0.hostname?.caseInsensitiveCompare(hostname) == .orderedSame
        } == true
    }
}

private struct CloudflareRulesetDTO: Decodable {
    let id: String
    let name: String?
    let kind: String?
    let phase: String?
    let rules: [CloudflareRulesetRuleDTO]?
}

private struct CloudflareRulesetRuleDTO: Decodable {
    struct ActionParameters: Decodable {
        let bic: Bool?
    }

    let id: String
    let ref: String?
    let action: String?
    let expression: String?
    let actionParameters: ActionParameters?
    let enabled: Bool?
}

private struct CloudflareDNSRecordDTO: Decodable {
    let id: String
    let type: String
    let name: String
    let content: String
    let comment: String?
}

private extension JSONDecoder {
    static var cloudflare: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
