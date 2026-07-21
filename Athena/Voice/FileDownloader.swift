import Foundation

/// Robust large-file downloader: chunked (not byte-by-byte), reports progress,
/// resumes after interruptions, and retries with backoff.
final class FileDownloader: NSObject, @unchecked Sendable {

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: ((Double) -> Void)?
    private var resumeData: Data?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60        // per-chunk stall tolerance
        config.timeoutIntervalForResource = 3600     // whole-file budget
        config.waitsForConnectivity = true           // survives brief drops
        config.allowsExpensiveNetworkAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Downloads `url` to `destination`, retrying up to `maxAttempts` times.
    /// Resumes from where it left off when the server supports it.
    func download(from url: URL, to destination: URL,
                  maxAttempts: Int = 5,
                  progress: @escaping (Double) -> Void) async throws {
        self.progress = progress
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let tempURL = try await runTask(url: url)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                return
            } catch {
                lastError = error
                // Cancelled by user — don't retry.
                if (error as NSError).code == NSURLErrorCancelled { throw error }
                NSLog("[download] attempt %d/%d failed: %@", attempt, maxAttempts,
                      error.localizedDescription)
                if attempt < maxAttempts {
                    // Backoff: 2s, 4s, 8s, 16s
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }
        throw DownloadError(message: """
            Download failed after \(maxAttempts) attempts: \
            \(lastError?.localizedDescription ?? "unknown error"). \
            Check your connection, or download the files manually (see README).
            """)
    }

    private func runTask(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let task: URLSessionDownloadTask
            if let data = resumeData {
                NSLog("[download] resuming (%d bytes already fetched)", data.count)
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: url)
            }
            task.resume()
        }
    }

    func cancel() {
        session.invalidateAndCancel()
    }
}

extension FileDownloader: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progress?(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns — move it now.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            resumeData = nil
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }   // success already handled above
        // Stash resume data so the retry continues instead of restarting.
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
