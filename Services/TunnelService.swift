import Foundation

enum TunnelServiceEvent: Sendable {
    case log(String)
    case started(URL)
    case stopped
    case failed(String)
}

enum TunnelServiceError: LocalizedError {
    case cloudflaredUnavailable
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .cloudflaredUnavailable:
            "`cloudflared` was not found in the standard Homebrew paths."
        case .alreadyRunning:
            "A Cloudflare tunnel is already running."
        }
    }
}

final class TunnelService: @unchecked Sendable {
    typealias EventHandler = @Sendable (TunnelServiceEvent) -> Void

    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "com.macremote.tunnel-output")
    private var process: Process?
    private var outputSource: DispatchSourceRead?
    private var outputPipe: Pipe?
    private var publicURL: URL?
    private var stopping = false

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

        return lock.withLock {
            if process?.isRunning == true {
                if let publicURL {
                    return .running(publicURL)
                }
                return .starting
            }
            return localServerURL == nil ? .stopped : .ready
        }
    }

    func startQuickTunnel(localServerURL: URL, onEvent: @escaping EventHandler) throws {
        guard let path = cloudflaredPath() else {
            throw TunnelServiceError.cloudflaredUnavailable
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "tunnel",
            "--no-autoupdate",
            "--url",
            localServerURL.absoluteString
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        let source = DispatchSource.makeReadSource(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            queue: outputQueue
        )
        source.setEventHandler { [weak self, pipe] in
            let data = pipe.fileHandleForReading.availableData
            guard !data.isEmpty else { return }

            let text = String(decoding: data, as: UTF8.self)
            let lines = text
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for line in lines {
                onEvent(.log(line))
            }

            if let publicURL = Self.firstPublicURL(in: text),
               self?.publish(publicURL: publicURL) == true {
                onEvent(.started(publicURL))
            }
        }
        source.setCancelHandler { [pipe] in
            try? pipe.fileHandleForReading.close()
        }

        process.terminationHandler = { [weak self] process in
            self?.handleTermination(exitCode: process.terminationStatus, onEvent: onEvent)
        }

        try lock.withLock {
            if self.process?.isRunning == true {
                throw TunnelServiceError.alreadyRunning
            }
            self.process = process
            self.outputSource = source
            self.outputPipe = pipe
            self.publicURL = nil
            self.stopping = false
        }

        do {
            try process.run()
            source.resume()
            onEvent(.log("cloudflared started for \(localServerURL.absoluteString)."))
        } catch {
            lock.withLock {
                self.process = nil
                self.outputSource = nil
                self.outputPipe = nil
                self.publicURL = nil
                self.stopping = false
            }
            throw error
        }
    }

    func stop() {
        let runningProcess: Process? = lock.withLock {
            stopping = true
            outputSource?.cancel()
            outputSource = nil
            outputPipe = nil
            publicURL = nil
            return process
        }

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        } else {
            lock.withLock {
                process = nil
                stopping = false
            }
        }
    }

    static func firstPublicURL(in text: String) -> URL? {
        let pattern = #"https://[A-Za-z0-9-]+\.trycloudflare\.com"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return URL(string: String(text[swiftRange]))
    }

    private func publish(publicURL: URL) -> Bool {
        lock.withLock {
            guard self.publicURL == nil else { return false }
            self.publicURL = publicURL
            return true
        }
    }

    private func handleTermination(exitCode: Int32, onEvent: EventHandler) {
        let shouldNotify: Bool = lock.withLock {
            let wasStopping = stopping
            process = nil
            outputSource?.cancel()
            outputSource = nil
            outputPipe = nil
            publicURL = nil
            stopping = false
            return !wasStopping
        }

        guard shouldNotify else {
            onEvent(.stopped)
            return
        }

        if exitCode == 0 {
            onEvent(.stopped)
        } else {
            onEvent(.failed("cloudflared exited with status \(exitCode)."))
        }
    }
}
