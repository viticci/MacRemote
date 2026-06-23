import Foundation

extension TimeInterval {
    var formattedDuration: String {
        if self < 1 {
            return "\(Int(self * 1000)) ms"
        }
        return String(format: "%.2f s", self)
    }
}

extension Date {
    var shortTimeString: String {
        Self.logFormatter.string(from: self)
    }

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
