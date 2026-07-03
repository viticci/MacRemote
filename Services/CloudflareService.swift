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
    /// Set when the deploy found (or failed to check for) a leftover
    /// Cloudflare Access app from a pre-2026-07 MacRemote deploy.
    var legacyAccessCleanup: String?
    var apexFavicon: CloudflareApexFaviconOutcome?

    var publicURL: URL {
        URL(string: "https://\(hostname)")!
    }
}

/// Outcome of the optional apex-favicon step. Claude.ai resolves connector
/// icons through Google's favicon service, which looks up the registrable
/// domain (the zone apex, not the connector's subdomain) — an apex that
/// serves nothing means a generic-globe connector icon. This step is
/// best-effort: it never fails the deploy, it just reports here.
enum CloudflareApexFaviconOutcome: Equatable, Sendable {
    case provisioned(String)
    case skippedExistingFavicon
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var logMessage: String {
        switch self {
        case .provisioned(let detail):
            "Connector icon: \(detail)"
        case .skippedExistingFavicon:
            "Connector icon: the domain apex already serves a favicon, so it was left untouched."
        case .failed(let message):
            "Connector icon setup was skipped: \(message)"
        }
    }
}

struct CloudflareCustomDomainDraft: Equatable, Sendable {
    var selectedZoneID: String?
    var subdomain: String = "macremote"
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
    case missingAPIToken
    case insufficientPermissions(String)
    case missingAPIResult
    case api(String)

    static let apiTokenPermissions = "Account Cloudflare Tunnel Read and Write; and for the selected zone: Zone Read, and DNS Read and Write"

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
    /// Tests inject this; the default probes the live URL through `session`.
    private let apexFaviconProbe: (@Sendable (URL) async -> Bool)?

    init(
        session: URLSession = .shared,
        tokenProvider: WranglerOAuthTokenProvider = WranglerOAuthTokenProvider(),
        runner: ProcessRunner = ProcessRunner(),
        executablePath: @escaping @Sendable (String) -> String? = { ExecutableLocator.executablePath(named: $0) },
        apexFaviconProbe: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.runner = runner
        self.executablePath = executablePath
        self.apexFaviconProbe = apexFaviconProbe
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
        apiToken: String? = nil,
        provisionApexFavicon: Bool = false
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
            apiToken: apiToken
        )

        let tunnelName = Self.tunnelName(hostname: hostname)
        let legacyAccessCleanup = await removeLegacyAccessApplication(
            hostname: hostname,
            zoneID: zone.id,
            apiToken: apiToken
        )

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

        let tunnelToken = try await tunnelRunToken(tunnelID: tunnel.id, accountID: zone.accountID, apiToken: apiToken)
        var apexFavicon: CloudflareApexFaviconOutcome?
        if provisionApexFavicon {
            apexFavicon = await self.provisionApexFavicon(zone: zone, apiToken: apiToken)
        }
        return CloudflareCustomDomainDeployment(
            zone: zone,
            hostname: hostname,
            tunnelID: tunnel.id,
            tunnelName: tunnelName,
            tunnelToken: tunnelToken,
            legacyAccessCleanup: legacyAccessCleanup,
            apexFavicon: apexFavicon
        )
    }

    // MARK: - Apex favicon (connector icon)

    /// Worker name and route patterns are stable so re-deploys update in
    /// place instead of accumulating scripts or routes.
    static let apexFaviconWorkerName = "macremote-apex-favicon"

    static func apexFaviconRoutePatterns(zoneName: String) -> [String] {
        ["\(zoneName)/favicon.ico", "\(zoneName)/favicon.png"]
    }

    /// A self-contained Worker serving the bundled MacRemote favicon on the
    /// two favicon paths only — never the rest of the apex, so anything the
    /// user hosts (or later hosts) there is untouched.
    static func apexFaviconWorkerScript(icoBase64: String, pngBase64: String) -> String {
        """
        // MacRemote apex favicon — serves the connector icon at the zone apex so
        // Google's favicon service (which Claude.ai uses for connector icons)
        // can resolve it. Managed by MacRemote; safe to delete.
        const ASSETS = {
          "/favicon.ico": { b64: "\(icoBase64)", type: "image/x-icon" },
          "/favicon.png": { b64: "\(pngBase64)", type: "image/png" }
        };
        function bytes(b64) {
          const bin = atob(b64);
          const out = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
          return out;
        }
        export default {
          fetch(request) {
            const asset = ASSETS[new URL(request.url).pathname];
            if (!asset) return new Response("Not Found", { status: 404 });
            return new Response(bytes(asset.b64), {
              headers: { "Content-Type": asset.type, "Cache-Control": "public, max-age=86400" }
            });
          }
        };
        """
    }

    static func bundledFaviconAssets() -> (icoBase64: String, pngBase64: String)? {
        // Same bundled assets the local server serves on the connector host.
        guard let ico = LocalMCPServer.staticResourceData(fileName: "Favicon.ico"),
              let png = LocalMCPServer.staticResourceData(fileName: "Favicon.png") else {
            return nil
        }
        return (ico.base64EncodedString(), png.base64EncodedString())
    }

    /// Multipart body for the Workers script upload (module syntax).
    static func workerUploadBody(script: String, boundary: String) -> Data {
        var body = ""
        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"metadata\"\r\n"
        body += "Content-Type: application/json\r\n\r\n"
        body += #"{"main_module":"worker.js","compatibility_date":"2025-01-01"}"# + "\r\n"
        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n"
        body += "Content-Type: application/javascript+module\r\n\r\n"
        body += script + "\r\n"
        body += "--\(boundary)--\r\n"
        return Data(body.utf8)
    }

    func provisionApexFavicon(zone: CloudflareZone, apiToken: String? = nil) async -> CloudflareApexFaviconOutcome {
        let faviconURL = URL(string: "https://\(zone.name)/favicon.ico")!
        if await apexServesFavicon(at: faviconURL) {
            return .skippedExistingFavicon
        }
        guard let assets = Self.bundledFaviconAssets() else {
            return .failed("the bundled favicon resources are missing from the app.")
        }
        do {
            try await uploadApexFaviconWorker(
                accountID: zone.accountID,
                script: Self.apexFaviconWorkerScript(icoBase64: assets.icoBase64, pngBase64: assets.pngBase64),
                apiToken: apiToken
            )
            var notes: [String] = []
            if let dnsNote = try await ensureApexAddressRecord(zone: zone, apiToken: apiToken) {
                notes.append(dnsNote)
            }
            notes.append(contentsOf: try await ensureApexFaviconRoutes(zone: zone, apiToken: apiToken))
            let summary = "now serving the MacRemote favicon at https://\(zone.name)/favicon.ico"
            return .provisioned(([summary] + notes).joined(separator: " "))
        } catch let error as CloudflareServiceError {
            if case .insufficientPermissions = error {
                return .failed("the API token lacks Workers permissions. Add Account → Workers Scripts: Edit and Zone → Workers Routes: Edit, then deploy again. Everything else deployed normally.")
            }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func apexServesFavicon(at url: URL) async -> Bool {
        if let apexFaviconProbe {
            return await apexFaviconProbe(url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode == 200
    }

    private func uploadApexFaviconWorker(accountID: String, script: String, apiToken: String?) async throws {
        let token = try Self.hasToken(apiToken)
            ? apiToken!.trimmingCharacters(in: .whitespacesAndNewlines)
            : tokenProvider.token()
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/workers/scripts/\(Self.apexFaviconWorkerName)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let boundary = "macremote-worker-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.workerUploadBody(script: script, boundary: boundary)

        let data = try await send(request, operation: "upload the connector icon Worker")
        let decoded = try JSONDecoder.cloudflare.decode(CloudflareAPIResponse<CloudflareWorkerScriptDTO>.self, from: data)
        guard decoded.success else {
            throw CloudflareServiceError.api(decoded.errorMessage ?? "Cloudflare rejected the Worker upload.")
        }
    }

    /// A Workers route only runs on proxied traffic, so the apex needs at
    /// least one proxied address record. `100::` is the standard discard
    /// placeholder for Workers-only hostnames — no origin is ever contacted.
    private func ensureApexAddressRecord(zone: CloudflareZone, apiToken: String?) async throws -> String? {
        let existing: CloudflareAPIResponse<[CloudflareApexDNSRecordDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zone.id)/dns_records",
            apiToken: apiToken,
            operation: "read DNS records for \(zone.name)",
            queryItems: [URLQueryItem(name: "name", value: zone.name)]
        )
        let addressRecords = try existing.requiredResult()
            .filter { ["A", "AAAA", "CNAME"].contains($0.type) }
        if addressRecords.isEmpty {
            let _: CloudflareAPIResponse<CloudflareApexDNSRecordDTO> = try await request(
                method: "POST",
                path: "/zones/\(zone.id)/dns_records",
                apiToken: apiToken,
                operation: "create the apex DNS record for \(zone.name)",
                body: [
                    "type": "AAAA",
                    "name": zone.name,
                    "content": "100::",
                    "ttl": 1,
                    "proxied": true,
                    "comment": "MacRemote apex favicon (Workers route target)"
                ]
            )
            return nil
        }
        if !addressRecords.contains(where: { $0.proxied == true }) {
            return "Note: the apex DNS record is not proxied (gray cloud), so the favicon Worker will not run until it is."
        }
        return nil
    }

    private func ensureApexFaviconRoutes(zone: CloudflareZone, apiToken: String?) async throws -> [String] {
        let existing: CloudflareAPIResponse<[CloudflareWorkerRouteDTO]> = try await request(
            method: "GET",
            path: "/zones/\(zone.id)/workers/routes",
            apiToken: apiToken,
            operation: "list Workers routes for \(zone.name)"
        )
        let routes = try existing.requiredResult()
        var notes: [String] = []
        for pattern in Self.apexFaviconRoutePatterns(zoneName: zone.name) {
            if let match = routes.first(where: { $0.pattern == pattern }) {
                if match.script != Self.apexFaviconWorkerName {
                    notes.append("Note: \(pattern) is already routed to another Worker (\(match.script ?? "unnamed")) and was left untouched.")
                }
                continue
            }
            let _: CloudflareAPIResponse<CloudflareWorkerRouteCreatedDTO> = try await request(
                method: "POST",
                path: "/zones/\(zone.id)/workers/routes",
                apiToken: apiToken,
                operation: "create the Workers route \(pattern)",
                body: [
                    "pattern": pattern,
                    "script": Self.apexFaviconWorkerName
                ]
            )
        }
        return notes
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
        "\(hostname)/mcp*"
    }

    private static func legacyAccessApplicationDomains(hostname: String) -> [String] {
        [
            hostname,
            "\(hostname)/mcp/*"
        ]
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

    // MARK: - Legacy Cloudflare Access cleanup

    /// Pre-2026-07 MacRemote could put a Cloudflare Access wall on `/mcp*`.
    /// Access support is gone, so a deploy removes MacRemote's own leftover
    /// Access app — otherwise old deploys stay walled off with no way to fix
    /// it from the app. Best-effort: current API tokens no longer carry
    /// Access permissions, and a failed check must never fail the deploy.
    private func removeLegacyAccessApplication(
        hostname: String,
        zoneID: String,
        apiToken: String?
    ) async -> String? {
        do {
            guard let app = try await existingAccessApplication(hostname: hostname, zoneID: zoneID, apiToken: apiToken) else {
                return nil
            }
            guard Self.isMacRemoteAccessApplication(app) else {
                return "A Cloudflare Access application not created by MacRemote guards \(hostname). MacRemote left it untouched; remove it in the Zero Trust dashboard if apps can't connect."
            }
            try await deleteAccessApplication(appID: app.id, zoneID: zoneID, apiToken: apiToken)
            return "Removed the Cloudflare Access app that an earlier MacRemote version put on \(hostname)/mcp — sign-in is now handled by MacRemote alone."
        } catch {
            return nil
        }
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
        let currentDomain = Self.accessApplicationDomain(hostname: hostname)
        let legacyDomains = Self.legacyAccessApplicationDomains(hostname: hostname)
        return apps.first { $0.domain == currentDomain } ??
            apps.first { app in
                guard let domain = app.domain else { return false }
                return legacyDomains.contains(domain)
            }
    }

    private static func isMacRemoteAccessApplication(_ app: CloudflareAccessApplicationDTO) -> Bool {
        app.name?.hasPrefix("MacRemote ") == true
    }

    private func deleteAccessApplication(
        appID: String,
        zoneID: String,
        apiToken: String?
    ) async throws {
        let _: CloudflareAPIResponse<EmptyResult> = try await request(
            method: "DELETE",
            path: "/zones/\(zoneID)/access/apps/\(appID)",
            apiToken: apiToken,
            operation: "delete Cloudflare Access application"
        )
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

        let data = try await send(request, operation: operation)
        let decoded = try JSONDecoder.cloudflare.decode(T.self, from: data)
        if let apiResponse = decoded as? AnyCloudflareAPIResponse, !apiResponse.isSuccess {
            throw CloudflareServiceError.api(apiResponse.errorMessage ?? "Cloudflare API request failed.")
        }
        return decoded
    }

    /// Shared transport + error mapping for JSON and multipart requests.
    private func send(_ request: URLRequest, operation: String) async throws -> Data {
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
        return data
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

private struct CloudflareApexDNSRecordDTO: Decodable {
    let id: String
    let type: String
    let proxied: Bool?
}

private struct CloudflareWorkerRouteDTO: Decodable {
    let id: String
    let pattern: String
    let script: String?
}

private struct CloudflareWorkerRouteCreatedDTO: Decodable {
    let id: String?
}

private struct CloudflareWorkerScriptDTO: Decodable {
    let id: String?
}

/// Kept only for the legacy Access cleanup step.
private struct CloudflareAccessApplicationDTO: Decodable {
    let id: String
    let name: String?
    let domain: String?
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
