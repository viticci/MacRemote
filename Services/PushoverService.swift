import Foundation

enum PushoverServiceError: LocalizedError, Equatable {
    case missingCredentials
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Add your Pushover User Key and API Token in Settings, then try again."
        case .invalidResponse:
            "Pushover returned an invalid response."
        case .api(let message):
            message
        }
    }
}

protocol PushoverSending: Sendable {
    func send(_ message: PushoverMessage, using settings: PushoverSettings) async throws
}

struct PushoverService: PushoverSending {
    private struct APIResponse: Decodable {
        let status: Int?
        let errors: [String]?
    }

    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.pushover.net/1/messages.json")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func send(_ message: PushoverMessage, using settings: PushoverSettings) async throws {
        guard settings.isConfigured else {
            throw PushoverServiceError.missingCredentials
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formBody([
            "token": settings.trimmedAPIToken,
            "user": settings.trimmedUserKey,
            "title": message.title,
            "message": message.message
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushoverServiceError.invalidResponse
        }

        let apiResponse = try? JSONDecoder().decode(APIResponse.self, from: data)
        guard (200..<300).contains(httpResponse.statusCode),
              apiResponse?.status == 1 else {
            throw PushoverServiceError.api(
                apiResponse?.errors?.joined(separator: " ") ?? "Pushover rejected the notification."
            )
        }
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let text = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(formEncode(key))=\(formEncode(value))"
            }
            .joined(separator: "&")
        return Data(text.utf8)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
