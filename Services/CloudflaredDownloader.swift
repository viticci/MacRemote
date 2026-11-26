import Foundation

enum CloudflaredDownloadError: LocalizedError, Equatable {
    case blockedURL(String)
    case blockedRedirect(String)
    case tooManyRedirects
    case badStatus(Int)
    case oversize
    case sizeMismatch(expected: Int, actual: Int)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .blockedURL(let host):
            "MacRemote only downloads Cloudflare's helper from Cloudflare's own release hosts, not \(host)."
        case .blockedRedirect(let host):
            "The download was redirected to \(host), which MacRemote does not trust. Nothing was saved."
        case .tooManyRedirects:
            "The download was redirected too many times. Nothing was saved."
        case .badStatus(let code):
            "The download server answered with status \(code)."
        case .oversize:
            "The download was larger than the release Cloudflare published, so it was discarded."
        case .sizeMismatch(let expected, let actual):
            "The download is \(actual) bytes but Cloudflare published \(expected) bytes, so it was discarded."
        case .transport(let message):
            message
        case .cancelled:
            "The download was cancelled."
        }
    }
}

/// Fetches one pinned release archive over HTTPS with a strict redirect
/// allowlist and a hard byte cap. It verifies nothing about the contents —
/// that is `CloudflaredArchiveExtractor`'s job — it only refuses to keep more
/// or fewer bytes than Cloudflare published.
struct CloudflaredDownloader: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// Downloads `artifact` to `destination`, reporting 0…1 progress. The
    /// destination is written only for a complete, exactly sized transfer.
    func download(
        artifact: CloudflaredArtifact,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard CloudflaredManifest.isAllowedDownloadURL(artifact.downloadURL) else {
            throw CloudflaredDownloadError.blockedURL(artifact.downloadURL.host() ?? "an unknown host")
        }

        var request = URLRequest(url: artifact.downloadURL)
        request.httpMethod = "GET"
        request.setValue("MacRemote", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let delegate = CloudflaredDownloadDelegate(
            expectedByteCount: artifact.archiveByteCount,
            maxByteCount: CloudflaredManifest.maxDownloadByteCount,
            onProgress: onProgress
        )
        let holder = CloudflaredDownloadTaskHolder()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // The completion-handler form keeps the delegate free of the
                // download-completion callbacks, so only redirect policy and
                // progress run through it.
                let task = session.downloadTask(with: request) { temporaryURL, response, error in
                    let outcome = Self.finish(
                        temporaryURL: temporaryURL,
                        response: response,
                        error: error,
                        refusal: delegate.refusal,
                        artifact: artifact,
                        destination: destination
                    )
                    switch outcome {
                    case .success:
                        onProgress(1)
                        continuation.resume()
                    case .failure(let failure):
                        continuation.resume(throwing: failure)
                    }
                }
                task.delegate = delegate
                holder.store(task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private static func finish(
        temporaryURL: URL?,
        response: URLResponse?,
        error: (any Error)?,
        refusal: CloudflaredDownloadError?,
        artifact: CloudflaredArtifact,
        destination: URL
    ) -> Result<Void, any Error> {
        func discard() {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        if let refusal {
            discard()
            return .failure(refusal)
        }
        if let error {
            discard()
            if (error as? URLError)?.code == .cancelled {
                return .failure(CloudflaredDownloadError.cancelled)
            }
            return .failure(CloudflaredDownloadError.transport(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            discard()
            return .failure(CloudflaredDownloadError.transport("The download server returned a non-HTTP response."))
        }
        guard http.statusCode == 200 else {
            discard()
            return .failure(CloudflaredDownloadError.badStatus(http.statusCode))
        }
        guard let temporaryURL else {
            return .failure(CloudflaredDownloadError.transport("The download produced no file."))
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        guard byteCount == artifact.archiveByteCount else {
            discard()
            return .failure(
                CloudflaredDownloadError.sizeMismatch(expected: artifact.archiveByteCount, actual: byteCount)
            )
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            discard()
            return .failure(CloudflaredDownloadError.transport(error.localizedDescription))
        }
        return .success(())
    }
}

private final class CloudflaredDownloadTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func store(_ task: URLSessionTask) {
        let shouldCancel: Bool = lock.withLock {
            self.task = task
            return isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task: URLSessionTask? = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// Per-task delegate: enforces the redirect allowlist and the byte cap, and
/// publishes determinate progress.
private final class CloudflaredDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedByteCount: Int
    private let maxByteCount: Int
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var redirectCount = 0
    private var storedRefusal: CloudflaredDownloadError?

    init(
        expectedByteCount: Int,
        maxByteCount: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.expectedByteCount = expectedByteCount
        self.maxByteCount = maxByteCount
        self.onProgress = onProgress
    }

    var refusal: CloudflaredDownloadError? {
        lock.withLock { storedRefusal }
    }

    private func refuse(_ error: CloudflaredDownloadError) {
        lock.withLock {
            if storedRefusal == nil {
                storedRefusal = error
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let overLimit: Bool = lock.withLock {
            redirectCount += 1
            return redirectCount > CloudflaredManifest.maxRedirectCount
        }
        if overLimit {
            refuse(.tooManyRedirects)
            task.cancel()
            completionHandler(nil)
            return
        }
        guard CloudflaredManifest.isAllowedDownloadURL(request.url) else {
            refuse(.blockedRedirect(request.url?.host() ?? "an unknown host"))
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > Int64(maxByteCount) || totalBytesWritten > Int64(expectedByteCount) {
            refuse(.oversize)
            downloadTask.cancel()
            return
        }
        guard expectedByteCount > 0 else { return }
        onProgress(min(1, max(0, Double(totalBytesWritten) / Double(expectedByteCount))))
    }

    /// Never called for a completion-handler download task; required by the
    /// protocol, so it stays a no-op that leaves the file where URLSession put it.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
