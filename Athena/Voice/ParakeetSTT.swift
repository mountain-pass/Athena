import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
#endif

struct TimeoutError: Error {}

/// Runs `work`, throwing `TimeoutError` if it outlives `seconds`.
/// Whichever finishes first wins; the loser is cancelled.
func withTimeout<T: Sendable>(seconds: TimeInterval,
                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return first
    }
}

/// Audio constants, kept outside the `@MainActor` class so the audio thread
/// and the ASR actor can read them without hopping actors.
enum ParakeetAudio {
    /// Sample rate Parakeet requires. All captured audio is resampled to this.
    static let sampleRate: Double = 16_000

    /// Parakeet's batch API is designed around ~15s windows — that's why
    /// FluidAudio ships a separate sliding-window manager for long audio.
    /// Handing it a minutes-long buffer in one call is pathologically slow,
    /// so we split long recordings ourselves.
    static let chunkSeconds: Double = 15
    static var chunkLength: Int { Int(sampleRate * chunkSeconds) }
}

/// Parakeet TDT speech-to-text, running on the Apple Neural Engine.
///
/// Why this exists: Apple's `SFSpeechRecognizer` is tuned for short command
/// phrases. On long-form dictation it misrecognises heavily, and — worse — its
/// on-device path goes dormant after a few seconds of silence, emitting no
/// final and no error, so a thinking pause silently ends the session.
///
/// Parakeet is a BATCH model, which removes that entire problem class. We
/// accumulate audio for as long as SPACE is held and transcribe the whole
/// buffer at once. A pause is just quiet samples; there is no session to
/// expire, nothing to rotate, and no partial state to lose.
///
/// Models (~600MB) download once from HuggingFace into
/// `~/.cache/fluidaudio/Models/` and are managed by FluidAudio itself.
@MainActor
final class ParakeetSTT: ObservableObject {

    enum Status: Equatable {
        case notLoaded
        case preparing
        case ready
        case unavailable(String)

        var isBusy: Bool { self == .preparing }

        var label: String {
            switch self {
            case .notLoaded:
                "Not loaded — downloads once (~600MB) on first use"
            case .preparing:
                "Downloading and loading model… this can take a few minutes"
            case .ready:
                "Ready — running on the Neural Engine"
            case .unavailable(let why):
                "Unavailable: \(why)"
            }
        }
    }

    /// Which Parakeet weights to use.
    enum ModelVersion: String, CaseIterable, Identifiable {
        case v3 = "v3 (multilingual — 25 European languages)"
        case v2 = "v2 (English only — highest accuracy)"
        var id: String { rawValue }
    }

    @Published private(set) var status: Status = .notLoaded
    @Published var modelVersion: ModelVersion = .v3 {
        didSet {
            guard oldValue != modelVersion else { return }
            UserDefaults.standard.set(modelVersion.rawValue, forKey: "stt.parakeet.version")
            // Abandon any in-flight load for the PREVIOUS version. Without
            // this, prepare() would see a non-nil loadTask and await the old
            // download, then report ready for a model we no longer want.
            loadTask?.cancel()
            loadTask = nil
            progressPoll?.cancel()
            progressPoll = nil
            Task { await runner.unload() }
            status = .notLoaded
            refreshDownloadState()
        }
    }

    private let runner = ParakeetRunner()

    // MARK: Download state
    //
    // Knowing whether the weights are on disk — without loading them — lets
    // setup prompt for the download up front instead of stalling the first
    // recording behind a silent 600MB fetch.

    /// Where FluidAudio caches its CoreML bundles.
    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
    }

    /// True when Parakeet weights are already on disk.
    @Published private(set) var isDownloaded = false
    /// Bytes on disk, for the setup UI.
    @Published private(set) var downloadedBytes: Int64 = 0

    /// Approximate finished size, used to turn bytes-on-disk into a progress
    /// fraction. FluidAudio downloads internally and offers no progress
    /// callback, so measuring the cache directory is the only honest signal
    /// available — better than a spinner that can't distinguish slow from stuck.
    var expectedBytes: Int64 { 620_000_000 }

    /// 0…1 while downloading. Clamped just below 1 so it never reads "100%"
    /// while there's still work happening.
    var downloadProgress: Double? {
        guard status == .preparing, downloadedBytes > 0 else { return nil }
        return min(0.99, Double(downloadedBytes) / Double(expectedBytes))
    }

    var progressDetail: String? {
        guard status == .preparing, downloadedBytes > 0 else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: downloadedBytes)) of ~\(f.string(fromByteCount: expectedBytes))"
    }

    /// Phase for the shared ModelDownloadRow.
    var phase: ModelPhase {
        switch status {
        case .ready:
            return .ready("Ready — running on the Neural Engine")
        case .preparing:
            // Once the bytes are all down, we're loading/compiling, not fetching.
            if isDownloaded, downloadedBytes >= expectedBytes {
                return .loading("Compiling model for the Neural Engine…")
            }
            return .downloading(downloadProgress)
        case .unavailable(let why):
            return .failed(why)
        case .notLoaded:
            return isDownloaded
                ? .loading("Installed (\(downloadedSizeLabel)) — not yet loaded")
                : .absent("Not downloaded — voice input is unavailable until you do")
        }
    }

    /// Polls the cache while a download runs so the bar actually moves.
    private var progressPoll: Task<Void, Never>?

    private func startProgressPolling() {
        progressPoll?.cancel()
        progressPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.status == .preparing else { return }
                self.refreshDownloadState()
            }
        }
    }

    /// Cheap disk check, off the main thread.
    func refreshDownloadState() {
        let dir = Self.cacheDirectory
        Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var bytes: Int64 = 0
            var found = false
            // Total everything in the cache: mid-download FluidAudio may be
            // writing to temporary names, so restricting the byte count to
            // "parakeet"-named entries would leave the progress bar at zero
            // for most of the download.
            if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e {
                    bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
            // Completion, though, requires the real bundle to exist by name.
            if let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) {
                found = entries.contains { $0.lastPathComponent.lowercased().contains("parakeet") }
            }
            // A partial download is worse than none — it loads and then fails.
            let complete = found && bytes > 100_000_000
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isDownloaded = complete
                self.downloadedBytes = bytes
                // Only now — with the weights confirmed present — is it safe
                // to honour a warm-up request without triggering a download.
                if complete, self.warmRequested, self.status == .notLoaded {
                    self.warmRequested = false
                    Task { await self.prepare() }
                }
            }
        }
    }

    /// Deletes the cached weights so the next download starts clean.
    /// A half-written bundle loads and then fails in confusing ways, so this
    /// is the right first move whenever a download was interrupted.
    func deleteDownload() {
        loadTask?.cancel(); loadTask = nil
        progressPoll?.cancel(); progressPoll = nil
        let dir = Self.cacheDirectory
        Task { [weak self] in
            await self?.runner.unload()
            try? FileManager.default.removeItem(at: dir)
            NSLog("[parakeet] cleared model cache at %@", dir.path)
            await MainActor.run { [weak self] in
                self?.status = .notLoaded
                self?.refreshDownloadState()
            }
        }
    }

    var downloadedSizeLabel: String {
        guard downloadedBytes > 0 else { return "not downloaded" }
        return ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var isAvailable: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "stt.parakeet.version"),
           let v = ModelVersion(rawValue: raw) {
            modelVersion = v
        }
        refreshDownloadState()
    }

    /// In-flight load, so concurrent callers await the same work instead of
    /// bailing out early. Without this, releasing SPACE while the launch-time
    /// warm-up is still running would return an empty transcript.
    private var loadTask: Task<Void, Never>?

    /// Explicit, user-initiated download + load. This is the ONLY path that
    /// is allowed to pull weights over the network.
    func downloadAndLoad() async {
        await prepare()
        refreshDownloadState()
    }

    /// Downloads (first run) and loads the model. Safe to call repeatedly.
    func prepare() async {
        #if canImport(FluidAudio)
        if status == .ready { return }
        if let loadTask {
            await loadTask.value
            return
        }
        status = .preparing
        let version = modelVersion
        NSLog("[parakeet] preparing %@ — first run downloads ~600MB from HuggingFace into ~/.cache/fluidaudio, which can take several minutes",
              version.rawValue)
        startProgressPolling()

        // Heartbeat: without this a long download looks identical to a hang.
        let heartbeat = Task { [weak self] in
            var waited = 0
            var lastBytes: Int64 = -1
            var stalledFor = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                waited += 5
                // This Task inherits the enclosing @MainActor context, so
                // `status` is readable directly.
                guard let self, self.status == .preparing else { return }

                let bytes = self.downloadedBytes
                // Reporting bytes turns "is it stuck?" from a guess into a fact.
                NSLog("[parakeet] still preparing… %ds elapsed, %lld bytes on disk (+%lld)",
                      waited, bytes, max(0, bytes - max(0, lastBytes)))

                if bytes > lastBytes {
                    stalledFor = 0
                } else {
                    stalledFor += 5
                }
                lastBytes = bytes

                // No growth for 90s while still well short of the full size
                // means the transfer died — those TCP resets in the log. Say
                // so instead of spinning forever.
                let nearlyComplete = bytes > Int64(Double(self.expectedBytes) * 0.9)
                if stalledFor >= 90, !nearlyComplete {
                    NSLog("[parakeet] download stalled at %lld bytes — giving up", bytes)
                    self.loadTask?.cancel()
                    self.loadTask = nil
                    self.progressPoll?.cancel()
                    self.status = .unavailable(
                        "Download stalled at \(self.downloadedSizeLabel). Check your connection and press Retry — it resumes from what's already downloaded.")
                    return
                }
            }
        }

        let task = Task { [weak self] in
            let started = Date()
            defer {
                heartbeat.cancel()
                Task { @MainActor [weak self] in self?.progressPoll?.cancel() }
            }
            do {
                try await self?.runner.load(version: version)
                await MainActor.run {
                    self?.status = .ready
                    self?.refreshDownloadState()
                    NSLog("[parakeet] ready in %.1fs (%@)",
                          Date().timeIntervalSince(started), version.rawValue)
                }
            } catch {
                await MainActor.run {
                    NSLog("[parakeet] load failed: %@", error.localizedDescription)
                    self?.status = .unavailable(error.localizedDescription)
                }
            }
            await MainActor.run { self?.loadTask = nil }
        }
        loadTask = task
        await task.value
        #else
        status = .unavailable("FluidAudio package not linked")
        #endif
    }

    /// Set when something asked us to warm up; honoured only once we've
    /// confirmed the weights are actually on disk.
    private var warmRequested = false

    /// Loads the model into memory IF it's already downloaded.
    ///
    /// Deliberately does NOT download. A 600MB fetch must be an explicit,
    /// visible action in setup or Settings — never something that silently
    /// starts because the user held SPACE.
    func warmUp() {
        guard isAvailable else { return }
        warmRequested = true
        refreshDownloadState()
    }

    /// Transcribes 16kHz mono Float32 samples. Runs off the main actor.
    ///
    /// Returns an empty string rather than throwing on an empty/short buffer,
    /// since that just means the user tapped SPACE without speaking.
    func transcribe(_ samples: [Float]) async throws -> String {
        #if canImport(FluidAudio)
        // Under ~0.2s of audio there is nothing to recognize and some model
        // paths dislike undersized inputs.
        guard samples.count > Int(ParakeetAudio.sampleRate * 0.2) else { return "" }
        // Awaits any in-flight load rather than returning empty.
        if status != .ready { await prepare() }
        guard status == .ready else {
            NSLog("[parakeet] not ready (%@) — cannot transcribe", status.label)
            return ""
        }

        // Short clip: one pass.
        guard samples.count > ParakeetAudio.chunkLength else {
            return try await runner.transcribe(samples)
        }

        // Long recording: split into ~15s pieces at quiet points and stitch.
        let chunks = Self.splitAtQuietPoints(samples)
        NSLog("[parakeet] %.1fs recording → %d chunks",
              Double(samples.count) / ParakeetAudio.sampleRate, chunks.count)
        var parts: [String] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let text = try await runner.transcribe(chunk)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
        #else
        return ""
        #endif
    }

    /// Splits audio into ~15s chunks, nudging each boundary to the quietest
    /// nearby point so a cut never lands in the middle of a word.
    /// Pure sample maths — no FluidAudio types, so it lives outside the
    /// conditional-compilation block.
    static func splitAtQuietPoints(_ samples: [Float]) -> [[Float]] {
        let target = ParakeetAudio.chunkLength
        // How far back from the target we'll look for a gap.
        let searchBack = Int(ParakeetAudio.sampleRate * 2.0)
        let window = Int(ParakeetAudio.sampleRate * 0.02)   // 20ms

        var chunks: [[Float]] = []
        var start = 0
        while start < samples.count {
            let remaining = samples.count - start
            if remaining <= target {
                chunks.append(Array(samples[start...]))
                break
            }

            // Scan the last 2s before the target boundary for the quietest
            // 20ms window — that's almost certainly a pause between words.
            let idealEnd = start + target
            let searchStart = max(start + window, idealEnd - searchBack)
            var bestCut = idealEnd
            var bestEnergy = Float.greatestFiniteMagnitude
            var i = searchStart
            while i + window <= idealEnd {
                var energy: Float = 0
                for j in i..<(i + window) { energy += samples[j] * samples[j] }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestCut = i + window / 2
                }
                i += window
            }

            chunks.append(Array(samples[start..<bestCut]))
            start = bestCut
        }
        return chunks
    }
}

/// Serialises access to the ASR model. `AsrManager` holds CoreML state that
/// must not be driven concurrently, and keeping it off the main actor means
/// transcription never blocks the UI.
actor ParakeetRunner {
    #if canImport(FluidAudio)
    private var manager: AsrManager?

    func load(version: ParakeetSTT.ModelVersion) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version == .v3 ? .v3 : .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func unload() {
        manager = nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { return "" }
        let started = Date()
        // FluidAudio 0.12.4 (the current release) takes an explicit TDT decoder
        // state. The `transcribe(_:source:)` form in the online docs describes
        // the unreleased main branch, which restructured this API — don't be
        // misled by it while we're pinned to a tagged release.
        //
        // A FRESH state per call is required, not a reused one: every call here
        // re-transcribes the entire buffer from the beginning (that's how the
        // rolling preview works), so carrying decoder state across calls would
        // corrupt the result.
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let elapsed = Date().timeIntervalSince(started)
        let audioSeconds = Double(samples.count) / ParakeetAudio.sampleRate
        NSLog("[parakeet] %.1fs audio → %d chars in %.2fs (%.0fx realtime)",
              audioSeconds, result.text.count, elapsed,
              elapsed > 0 ? audioSeconds / elapsed : 0)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #else
    func load(version: ParakeetSTT.ModelVersion) async throws {}
    func unload() {}
    func transcribe(_ samples: [Float]) async throws -> String { "" }
    #endif
}
