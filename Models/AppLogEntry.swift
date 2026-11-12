import Foundation

struct AppLogEntry: Identifiable, Hashable, Sendable {
    enum Level: String, Sendable {
        case info
        case warning
        case error

        var title: String {
            rawValue.capitalized
        }
    }

    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}
