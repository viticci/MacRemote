import Foundation

enum BrrrServiceError: LocalizedError, Equatable {
    case missingCredentials
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Enter a Brrr webhook secret before sending notifications."
        case .invalidResponse:
            "Brrr returned an invalid response."
        case .api(let message):
            message
        }
    }
}

protocol BrrrSending: Sendable {
    func send(_ message: BrrrMessage, using settings: BrrrSettings) async throws
}

struct BrrrService: BrrrSending {
    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.brrr.now/v1/send")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func send(_ message: BrrrMessage, using settings: BrrrSettings) async throws {
        guard settings.isConfigured else {
            throw BrrrServiceError.missingCredentials
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.trimmedWebhookSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("MacRemote/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try Self.jsonBody(for: message)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BrrrServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = body?.isEmpty == false ? body! : "HTTP \(httpResponse.statusCode)"
            throw BrrrServiceError.api("Brrr rejected the notification: \(detail)")
        }
    }

    static func jsonBody(for message: BrrrMessage) throws -> Data {
        var payload: [String: Any] = [
            "title": message.title,
            "message": message.message
        ]
        if let threadID = message.threadID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !threadID.isEmpty {
            payload["thread_id"] = threadID
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
