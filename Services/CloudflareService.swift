import Foundation

struct CloudflareZone: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let accountID: String
    let accountName: String
}

struct CloudflareAccessCredentials: Equatable, Sendable {
    let clientID: String
    let clientSecret: String

    var standardHeadersJSON: String {
        let payload = [
            "CF-Access-Client-Id": clientID,
            "CF-Access-Client-Secret": clientSecret
        ]
        return Self.prettyJSONString(payload)
    }

    var authorizationHeaderValue: String {
        let payload = [
            "cf-access-client-id": clientID,
            "cf-access-client-secret": clientSecret
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    var authorizationHeaderJSON: String {
        Self.prettyJSONString(["Authorization": authorizationHeaderValue])
    }

    func headersJSON(for mode: CloudflareAccessMode) -> String? {
        switch mode {
        case .macRemoteOAuthOnly:
            nil
        case .serviceTokenHeaders:
            standardHeadersJSON
        case .serviceTokenAuthorizationHeader:
            authorizationHeaderJSON
        }
    }

    private static func prettyJSONString(_ payload: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

struct CloudflareCustomDomainDeployment: Equatable, Sendable {
    let zone: CloudflareZone
    let hostname: String
    let tunnelID: String
    let tunnelName: String
    let tunnelToken: String
    let accessMode: CloudflareAccessMode
    let accessCredentials: CloudflareAccessCredentials?

    var publicURL: URL {
        URL(string: "https://\(hostname)")!
    }
}

struct CloudflareCustomDomainDraft: Equatable, Sendable {
    var selectedZoneID: String?
    var subdomain: String = "macremote"
    var accessMode: CloudflareAccessMode = .serviceTokenHeaders
    var apiToken: String = ""

    var trimmedAPIToken: String {
        apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CloudflareServiceError: LocalizedError, Equatable {
    case wranglerUnavailable
    case cloudflaredUnavailable
    case wranglerNotAuthenticated
    case invalidSubdomain
    case zoneRequired
    case existingDNSRecord(String)
    case existingAccessApplication(String)
    case missingAPIToken
    case insufficientPermissions(String)
    case missingAPIResult
    case api(String)

    static let apiTokenPermissions = "Account Cloudflare Tunnel Read and Write; and for the selected zone: Zone Read, DNS Read and Write, Access Apps and Policies Read and Write, and Access Service Tokens Read and Write"

    var errorDescription: String? {
        switch self {
        case .wranglerUnavailable:
            "`wrangler` was not found on PATH or in standard Homebrew paths."
        case .cloudflaredUnavailable:
            "`cloudflared` was not found on PATH or in standard Homebrew paths."
        case .wranglerNotAuthenticated:
            "Wrangler is not authenticated. Run `wrangler login` in Terminal."
        case .invalidSubdomain:
            "Enter a valid subdomain, such as `macremote` or `macremote-home`."
        case .zoneRequired:
            "Select a Cloudflare domain first."
        case .existingDNSRecord(let hostname):
            "A non-MacRemote DNS record already exists for \(hostname)."
        case .existingAccessApplication(let hostname):
            "A non-MacRemote Cloudflare Access application already exists for \(hostname)."
        case .missingAPIToken:
            "Paste a Cloudflare API token before deploying. Required permissions: \(Self.apiTokenPermissions)."
        case .insufficientPermissions(let operation):
            "Cloudflare rejected the API token while trying to \(operation). Required permissions: \(Self.apiTokenPermissions)."
        case .missingAPIResult:
            "Cloudflare returned a successful response without the expected result."
        case .api(let message):
            message
        }
    }
}

struct CloudflareService: Sendable {
    private let session: URLSession
    private let tokenProvider: WranglerOAuthTokenProvider
    private let runner: ProcessRunner
    private let executablePath: @Sendable (String) -> String?

    init(
        session: URLSession = .shared,
        tokenProvider: WranglerOAuthTokenProvider = WranglerOAuthTokenProvider(),
        runner: ProcessRunner = ProcessRunner(),
        executablePath: @escaping @Sendable (String) -> String? = { ExecutableLocator.executablePath(named: $0) }
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.runner = runner
        self.executablePath = executablePath
    }

    func wranglerPath() -> String? {
        executablePath("wrangler")
    }

    func cloudflaredPath() -> String? {
        executablePath("cloudflared")
    }

    func loadZones(apiToken: String? = nil) async throws -> [CloudflareZone] {
        try await refreshWranglerSessionIfPossible(apiToken: apiToken)
        let response: CloudflareAPIResponse<[CloudflareZoneDTO]> = try await request(
            method: "GET",
            path: "/zones",
            apiToken: apiToken,
            operation: "list Cloudflare zones",
            queryItems: [
                URLQueryItem(name: "per_page", value: "50"),
                URLQueryItem(name: "status", value: "active")
            ]
        )
        return try response.requiredResult().map { $0.zone }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func deployCustomDomain(
        zone: CloudflareZone,
        subdomain: String,
        localServerURL: URL,
        accessMode: CloudflareAccessMode,
        apiToken: String? = nil
    ) async throws -> CloudflareCustomDomainDeployment {
        guard cloudflaredPath() != nil else {
            throw CloudflareServiceError.cloudflaredUnavailable
        }
        try await refreshWranglerSessionIfPossible(apiToken: apiToken)

        let hostname = try Self.hostname(subdomain: subdomain, zoneName: zone.name)
        guard Self.hasToken(apiToken) else {
            throw CloudflareServiceError.missingAPIToken
        }
        try await preflightPermissions(
            zone: zone,
            hostname: hostname,
            accessMode: accessMode,
            apiToken: apiToken
        )

        let tunnelName = Self.tunnelName(hostname: hostname)
        let tunnel: CloudflareTunnelDTO
        if let existing = try await existingTunnel(named: tunnelName, accountID: zone.accountID, apiToken: apiToken) {
            tunnel = existing
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
        try await ensureDNSRecord(zoneID: zone.id, hostname: hostname, tunnelID: tunnel.id, apiToken: apiToken)

        let accessCredentials: CloudflareAccessCredentials?
        if accessMode.requiresCloudflareAccess {
            let app: CloudflareAccessApplicationDTO
            if let existing = try await existingAccessApplication(hostname: hostname, zoneID: zone.id, apiToken: apiToken) {
                guard existing.name?.hasPrefix("MacRemote ") == true else {
                    throw CloudflareServiceError.existingAccessApplication(hostname)
                }
                app = try await updateAccessApplication(
                    appID: existing.id,
                    hostname: hostname,
                    accessMode: accessMode,
                    zoneID: zone.id,
                    apiToken: apiToken
                )
            } else {
                app = try await createAccessApplication(
                    hostname: hostname,
                    accessMode: accessMode,
                    zoneID: zone.id,
                    apiToken: apiToken
                )
            }
            let serviceToken = try await createServiceToken(
                zoneID: zone.id,
                hostname: hostname,
                apiToken: apiToken
            )
            try await createServiceAuthPolicy(
                zoneID: zone.id,
                appID: app.id,
                hostname: hostname,
                serviceTokenID: serviceToken.id,
                apiToken: apiToken
            )
            accessCredentials = CloudflareAccessCredentials(
                clientID: serviceToken.clientId,
                clientSecret: serviceToken.clientSecret
            )
        } else {
            accessCredentials = nil
        }

        let tunnelToken = try await tunnelRunToken(tunnelID: tunnel.id, accountID: zone.accountID, apiToken: apiToken)
        return CloudflareCustomDomainDeployment(
            zone: zone,
            hostname: hostname,
            tunnelID: tunnel.id,
            tunnelName: tunnelName,
            tunnelToken: tunnelToken,
            accessMode: accessMode,
            accessCredentials: accessCredentials
        )
    }

    static func hostname(subdomain: String, zoneName: String) throws -> String {
        let normalized = subdomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard isValidSubdomain(normalized) else {
            throw CloudflareServiceError.invalidSubdomain
        }
        return "\(normalized).\(zoneName)"
    }

    static func isValidSubdomain(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count),
                  label.first?.isDNSLetterOrNumber == true,
                  label.last?.isDNSLetterOrNumber == true else {
                return false
            }
            return label.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-"
            }
        }
    }

    static func tunnelName(hostname: String) -> String {
        let suffix = hostname
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
        return "macremote-\(suffix)"
    }

    static func accessApplicationDomain(hostname: String) -> String {
        "\(hostname)/mcp/*"
    }

    private static func hasToken(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func refreshWranglerSessionIfPossible(apiToken: String?) async throws {
        if Self.hasToken(apiToken) {
            return
        }
        guard let wranglerPath = wranglerPath() else {
            throw CloudflareServiceError.wranglerUnavailable
        }
        let result = try await runner.run(
            executablePath: wranglerPath,
            arguments: ["whoami"],
            timeoutSeconds: 20,
            outputByteLimit: 8 * 1024,
            environment: ExecutableLocator.toolEnvironment
        )
        guard result.succeeded else {
            throw CloudflareServiceError.wranglerNotAuthenticated
        }
    }

    private func preflightPermissions(
        zone: CloudflareZone,
        hostname: String,
        accessMode: CloudflareAccessMode,
        apiToken: String?
    ) async throws {
        let _: CloudflareAPIResponse<[CloudflareTunnelDTO]> = try await request(
            method: "GET",
            path: "/accounts/\(zone.accountID)/cfd_tunnel",
            apiToken: apiToken,
            operation: "list Cloudflare Tunnels",
            queryItems: [
                URLQueryItem(name: "per_page", value: "1")
            ]
        )
        let _: CloudflareAPIResponse<[CloudflareDNSRecordDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zone.id)/dns_records",
            apiToken: apiToken,
            operation: "read DNS records for \(hostname)",
            queryItems: [
                URLQueryItem(name: "type", value: "CNAME"),
                URLQueryItem(name: "name", value: hostname)
            ]
        )
        guard accessMode.requiresCloudflareAccess else { return }
        let _: CloudflareAPIResponse<[CloudflareAccessApplicationDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zone.id)/access/apps",
            apiToken: apiToken,
            operation: "list Cloudflare Access applications",
            queryItems: [
                URLQueryItem(name: "per_page", value: "1")
            ]
        )
        let _: CloudflareAPIResponse<[CloudflareServiceTokenListDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zone.id)/access/service_tokens",
            apiToken: apiToken,
            operation: "list Cloudflare Access service tokens",
            queryItems: [
                URLQueryItem(name: "per_page", value: "1")
            ]
        )
    }

    private func existingTunnel(named name: String, accountID: String, apiToken: String?) async throws -> CloudflareTunnelDTO? {
        let response: CloudflareAPIResponse<[CloudflareTunnelDTO]> = try await request(
            method: "GET",
            path: "/accounts/\(accountID)/cfd_tunnel",
            apiToken: apiToken,
            operation: "list Cloudflare Tunnels",
            queryItems: [
                URLQueryItem(name: "per_page", value: "50"),
                URLQueryItem(name: "name", value: name)
            ]
        )
        return try response.requiredResult().first { $0.name == name && $0.deletedAt == nil }
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

    private func ensureDNSRecord(zoneID: String, hostname: String, tunnelID: String, apiToken: String?) async throws {
        let target = "\(tunnelID).cfargotunnel.com"
        let existingResponse: CloudflareAPIResponse<[CloudflareDNSRecordDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zoneID)/dns_records",
            apiToken: apiToken,
            operation: "read DNS records for \(hostname)",
            queryItems: [
                URLQueryItem(name: "type", value: "CNAME"),
                URLQueryItem(name: "name", value: hostname)
            ]
        )
        if let existing = try existingResponse.requiredResult().first {
            guard existing.content == target ||
                    existing.comment?.hasPrefix("MacRemote") == true else {
                throw CloudflareServiceError.existingDNSRecord(hostname)
            }
            let _: CloudflareAPIResponse<CloudflareDNSRecordDTO> = try await request(
                method: "PATCH",
                path: "/zones/\(zoneID)/dns_records/\(existing.id)",
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
            "comment": "MacRemote Cloudflare Tunnel"
        ]
    }

    private func createServiceToken(zoneID: String, hostname: String, apiToken: String?) async throws -> CloudflareServiceTokenDTO {
        let response: CloudflareAPIResponse<CloudflareServiceTokenDTO> = try await request(
            method: "POST",
            path: "/zones/\(zoneID)/access/service_tokens",
            apiToken: apiToken,
            operation: "create Cloudflare Access service token",
            body: [
                "name": "MacRemote \(hostname)",
                "duration": "8760h"
            ]
        )
        return try response.requiredResult()
    }

    private func existingAccessApplication(hostname: String, zoneID: String, apiToken: String?) async throws -> CloudflareAccessApplicationDTO? {
        let response: CloudflareAPIResponse<[CloudflareAccessApplicationDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zoneID)/access/apps",
            apiToken: apiToken,
            operation: "list Cloudflare Access applications",
            queryItems: [
                URLQueryItem(name: "per_page", value: "50")
            ]
        )
        let apps = try response.requiredResult()
        return apps.first { $0.domain == hostname } ??
            apps.first { $0.domain == Self.accessApplicationDomain(hostname: hostname) }
    }

    private func createAccessApplication(
        hostname: String,
        accessMode: CloudflareAccessMode,
        zoneID: String,
        apiToken: String?
    ) async throws -> CloudflareAccessApplicationDTO {
        let response: CloudflareAPIResponse<CloudflareAccessApplicationDTO> = try await request(
            method: "POST",
            path: "/zones/\(zoneID)/access/apps",
            apiToken: apiToken,
            operation: "create Cloudflare Access application",
            body: accessApplicationBody(hostname: hostname, accessMode: accessMode)
        )
        return try response.requiredResult()
    }

    private func updateAccessApplication(
        appID: String,
        hostname: String,
        accessMode: CloudflareAccessMode,
        zoneID: String,
        apiToken: String?
    ) async throws -> CloudflareAccessApplicationDTO {
        let response: CloudflareAPIResponse<CloudflareAccessApplicationDTO> = try await request(
            method: "PUT",
            path: "/zones/\(zoneID)/access/apps/\(appID)",
            apiToken: apiToken,
            operation: "update Cloudflare Access application",
            body: accessApplicationBody(hostname: hostname, accessMode: accessMode)
        )
        return try response.requiredResult()
    }

    private func accessApplicationBody(hostname: String, accessMode: CloudflareAccessMode) -> [String: Any] {
        var body: [String: Any] = [
            "name": "MacRemote \(hostname)",
            "domain": Self.accessApplicationDomain(hostname: hostname),
            "type": "self_hosted",
            "app_launcher_visible": false,
            "session_duration": "24h"
        ]
        if let headerName = accessMode.readServiceTokensFromHeader {
            body["read_service_tokens_from_header"] = headerName
        }
        return body
    }

    private func createServiceAuthPolicy(
        zoneID: String,
        appID: String,
        hostname: String,
        serviceTokenID: String,
        apiToken: String?
    ) async throws {
        let policies = try await accessPolicies(zoneID: zoneID, appID: appID, apiToken: apiToken)
        if let existing = policies.first(where: {
            $0.name?.hasPrefix("MacRemote Service Token") == true ||
            $0.name?.hasPrefix("MacRemote Raycast Service Token") == true
        }),
           let policyID = existing.id {
            let precedence = existing.precedence ?? Self.nextAccessPolicyPrecedence(after: policies)
            let _: CloudflareAPIResponse<CloudflareAccessPolicyDTO> = try await request(
                method: "PUT",
                path: "/zones/\(zoneID)/access/apps/\(appID)/policies/\(policyID)",
                apiToken: apiToken,
                operation: "update Cloudflare Access service-auth policy",
                body: serviceAuthPolicyBody(serviceTokenID: serviceTokenID, precedence: precedence)
            )
            return
        }

        let _: CloudflareAPIResponse<CloudflareAccessPolicyDTO> = try await request(
            method: "POST",
            path: "/zones/\(zoneID)/access/apps/\(appID)/policies",
            apiToken: apiToken,
            operation: "create Cloudflare Access service-auth policy",
            body: serviceAuthPolicyBody(
                serviceTokenID: serviceTokenID,
                precedence: Self.nextAccessPolicyPrecedence(after: policies)
            )
        )
    }

    private func accessPolicies(zoneID: String, appID: String, apiToken: String?) async throws -> [CloudflareAccessPolicyDTO] {
        let response: CloudflareAPIResponse<[CloudflareAccessPolicyDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zoneID)/access/apps/\(appID)/policies",
            apiToken: apiToken,
            operation: "list Cloudflare Access policies",
            queryItems: [
                URLQueryItem(name: "per_page", value: "50")
            ]
        )
        return try response.requiredResult()
    }

    private func serviceAuthPolicyBody(serviceTokenID: String, precedence: Int) -> [String: Any] {
        [
            "name": "MacRemote Service Token",
            "decision": "non_identity",
            "precedence": precedence,
            "session_duration": "24h",
            "include": [
                [
                    "service_token": [
                        "token_id": serviceTokenID
                    ]
                ]
            ]
        ] as [String: Any]
    }

    private static func nextAccessPolicyPrecedence(after policies: [CloudflareAccessPolicyDTO]) -> Int {
        let used = Set(policies.compactMap(\.precedence))
        var candidate = 1
        while used.contains(candidate) {
            candidate += 1
        }
        return candidate
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

    private func request<T: Decodable>(
        method: String,
        path: String,
        apiToken: String? = nil,
        operation: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> T {
        let token = try Self.hasToken(apiToken) ? apiToken!.trimmingCharacters(in: .whitespacesAndNewlines) : tokenProvider.token()
        var components = URLComponents(string: "https://api.cloudflare.com/client/v4\(path)")!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareServiceError.api("Cloudflare returned a non-HTTP response.")
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            let message = CloudflareAPIErrorMessage.message(from: data) ??
                "Cloudflare API returned HTTP \(httpResponse.statusCode)."
            if httpResponse.statusCode == 403, message.localizedCaseInsensitiveContains("authentication error") {
                throw CloudflareServiceError.insufficientPermissions(operation)
            }
            throw CloudflareServiceError.api(message)
        }

        let decoded = try JSONDecoder.cloudflare.decode(T.self, from: data)
        if let apiResponse = decoded as? AnyCloudflareAPIResponse, !apiResponse.isSuccess {
            throw CloudflareServiceError.api(apiResponse.errorMessage ?? "Cloudflare API request failed.")
        }
        return decoded
    }
}

struct WranglerOAuthTokenProvider: Sendable {
    var configFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/.wrangler/config/default.toml")

    func token() throws -> String {
        guard let text = try? String(contentsOf: configFileURL, encoding: .utf8),
              let value = Self.value(named: "oauth_token", in: text),
              !value.isEmpty else {
            throw CloudflareServiceError.wranglerNotAuthenticated
        }
        return value
    }

    static func value(named key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(key)"),
                  let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            var value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }
}

private struct CloudflareAPIResponse<Result: Decodable>: Decodable, AnyCloudflareAPIResponse {
    let success: Bool
    let errors: [CloudflareAPIMessage]
    let messages: [CloudflareAPIMessage]
    let result: Result?

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

private struct CloudflareTunnelConfigurationDTO: Decodable {}

private struct CloudflareDNSRecordDTO: Decodable {
    let id: String
    let name: String
    let content: String
    let comment: String?
}

private struct CloudflareServiceTokenDTO: Decodable {
    let id: String
    let clientId: String
    let clientSecret: String
}

private struct CloudflareServiceTokenListDTO: Decodable {
    let id: String
    let name: String?
}

private struct CloudflareAccessApplicationDTO: Decodable {
    let id: String
    let name: String?
    let domain: String?
}

private struct CloudflareAccessPolicyDTO: Decodable {
    let id: String?
    let name: String?
    let precedence: Int?
}

private extension JSONDecoder {
    static var cloudflare: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private extension Character {
    var isDNSLetterOrNumber: Bool {
        isLetter || isNumber
    }
}
