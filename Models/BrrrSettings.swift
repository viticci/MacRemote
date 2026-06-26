import Foundation

struct BrrrSettings: Equatable, Sendable {
    var isEnabled: Bool = false
    var webhookSecret: String = ""

    var trimmedWebhookSecret: String {
        webhookSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        isEnabled && !trimmedWebhookSecret.isEmpty
    }
}

struct BrrrMessage: Equatable, Sendable {
    let title: String
    let message: String
    var threadID: String?
}
