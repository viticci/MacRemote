import Foundation

struct AppLogEntry: Identifiable, Hashable {
    enum Level: String {
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
