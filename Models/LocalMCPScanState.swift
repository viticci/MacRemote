import Foundation

enum LocalMCPScanState: Equatable, Sendable {
    case idle
    case scanning
    case loaded([LocalMCPServerCandidate], Date)
    case failed(String)

    var isScanning: Bool {
        if case .scanning = self {
            return true
        }
        return false
    }

    var candidates: [LocalMCPServerCandidate] {
        switch self {
        case .loaded(let candidates, _):
            return candidates
        case .idle, .scanning, .failed:
            return []
        }
    }

    var lastScanDate: Date? {
        if case .loaded(_, let date) = self {
            return date
        }
        return nil
    }

    func candidate(id: String) -> LocalMCPServerCandidate? {
        candidates.first { $0.id == id }
    }

    /// Adds a candidate the scanner synthesized on demand, replacing any
    /// loaded candidate with the same id. An idle or failed state becomes a
    /// loaded one so the import UI can address it.
    func insertingCandidate(_ candidate: LocalMCPServerCandidate) -> LocalMCPScanState {
        switch self {
        case .loaded(var candidates, let date):
            if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
                candidates[index] = candidate
            } else {
                candidates.append(candidate)
            }
            return .loaded(candidates, date)
        case .idle, .scanning, .failed:
            return .loaded([candidate], Date())
        }
    }

    func replacingCandidate(_ candidate: LocalMCPServerCandidate) -> LocalMCPScanState {
        switch self {
        case .loaded(var candidates, let date):
            if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
                candidates[index] = candidate
            }
            return .loaded(candidates, date)
        case .idle, .scanning, .failed:
            return self
        }
    }
}
