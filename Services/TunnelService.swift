import Foundation

struct TunnelService {
    func cloudflaredPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func status(localServerURL: URL?) -> TunnelStatus {
        guard cloudflaredPath() != nil else {
            return .unavailable
        }
        return localServerURL == nil ? .stopped : .ready
    }
}
