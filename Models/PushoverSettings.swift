import Foundation

struct PushoverSettings: Equatable, Sendable {
    var isEnabled: Bool = false
    var userKey: String = ""
    var apiToken: String = ""

    var trimmedUserKey: String {
        userKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAPIToken: String {
        apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        isEnabled && !trimmedUserKey.isEmpty && !trimmedAPIToken.isEmpty
    }
}

struct PushoverMessage: Equatable, Sendable {
    let title: String
    let message: String
}
