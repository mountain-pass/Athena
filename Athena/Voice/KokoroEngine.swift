import Foundation
import AVFoundation

#if canImport(Kokoro)
import Kokoro
#endif

/// Embedded Kokoro-82M TTS — fully on-device, no server, no Docker.
///
/// Pipeline: text → Misaki G2P (Swift) → Kokoro model (MLX/Metal) → 24kHz audio.
///
/// Assets live in Application Support/Athena/Kokoro:
///   config.json                 (model config)
///   kokoro-v1_0.safetensors     (~330MB MLX weights)
///   voices/<id>.<ext>           (auto-downloaded on demand by VoiceLoader)
///
/// Model weights are NOT bundled — they download once from HuggingFace
/// (mweinbach/Kokoro-82M-Swift) on first use.
@MainActor
final class KokoroEngine: ObservableObject {

    enum Status: Equatable {
        case notLoaded
        case downloading(Double)     // 0…1
        case loading
        case ready
        case unavailable(String)

        var label: String {
            switch self {
            case .notLoaded: "Not loaded — click below to download (~330MB, one time)"
            case .downloading(let p): "Downloading model… \(Int(p * 100))%"
            case .loading: "Loading model into memory…"
            case .ready: "Ready — running on-device"
            case .unavailable(let why): "Unavailable: \(why)"
            }
        }
    }

    @Published private(set) var status: Status = .notLoaded

    /// Popular English voices (the package ships 54 across 8 languages).
    static let voices: [(id: String, label: String)] = [
        ("af_heart",    "Heart (US female, warm)"),
        ("af_bella",    "Bella (US female)"),
        ("af_nicole",   "Nicole (US female, soft)"),
        ("af_sarah",    "Sarah (US female)"),
        ("af_sky",      "Sky (US female)"),
        ("am_michael",  "Michael (US male)"),
        ("am_adam",     "Adam (US male)"),
        ("am_echo",     "Echo (US male)"),
        ("bf_emma",     "Emma (UK female)"),
        ("bf_isabella", "Isabella (UK female)"),
        ("bm_george",   "George (UK male)"),
        ("bm_lewis",    "Lewis (UK male)"),
    ]

    var isAvailable: Bool {
        #if canImport(Kokoro)
        return true
        #else
        return false
        #endif
    }

    // MARK: Asset locations

    static var assetDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Athena/Kokoro", isDirectory: true)
    }
    private static var configURL: URL { assetDirectory.appendingPathComponent("config.json") }
    private static var weightsURL: URL { assetDirectory.appendingPathComponent("kokoro-v1_0.safetensors") }
    private static var voicesDirectory: URL { assetDirectory.appendingPathComponent("voices", isDirectory: true) }

    /// HuggingFace source for the converted MLX weights.
    private static let repoBase = "https://huggingface.co/mweinbach/Kokoro-82M-Swift/resolve/main/MLX_GPU"

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: Self.weightsURL.path)
            && FileManager.default.fileExists(atPath: Self.configURL.path)
    }

    /// Model loading and inference run inside this actor — OFF the main thread.
    /// (Doing it on @MainActor froze the whole UI, which looked like a hang.)
    private let runner = KokoroRunner()

    // MARK: Loading

    func prepare() async {
        #if canImport(Kokoro)
        if await runner.isLoaded { status = .ready; return }
        do {
            if !isDownloaded { try await downloadAssets() }
            status = .loading
            try FileManager.default.createDirectory(at: Self.voicesDirectory,
                                                    withIntermediateDirectories: true)
            try await runner.load(configURL: Self.configURL,
                                  weightsURL: Self.weightsURL,
                                  voicesDirectory: Self.voicesDirectory)
            status = .ready
        } catch {
            status = .unavailable(error.localizedDescription)
        }
        #else
        status = .unavailable("Kokoro package not linked — run `xcodegen`, then build once to resolve packages")
        #endif
    }

    private var downloader: FileDownloader?

    private func downloadAssets() async throws {
        try FileManager.default.createDirectory(at: Self.assetDirectory,
                                                withIntermediateDirectories: true)
        status = .downloading(0)
        let downloader = FileDownloader()
        self.downloader = downloader
        defer { self.downloader = nil }

        // Small config file (no visible progress needed).
        if !FileManager.default.fileExists(atPath: Self.configURL.path) {
            guard let configURL = URL(string: "\(Self.repoBase)/config.json") else {
                throw TTSError.badURL
            }
            try await downloader.download(from: configURL, to: Self.configURL) { _ in }
        }

        // Large weights — chunked, resumable, retried.
        guard let weightsURL = URL(string: "\(Self.repoBase)/kokoro-v1_0.safetensors") else {
            throw TTSError.badURL
        }
        try await downloader.download(from: weightsURL, to: Self.weightsURL) { fraction in
            Task { @MainActor in self.status = .downloading(fraction) }
        }
    }

    /// Cancels an in-flight download.
    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        status = isDownloaded ? .notLoaded : .notLoaded
    }

    /// Deletes downloaded assets (frees ~330MB).
    func deleteAssets() {
        try? FileManager.default.removeItem(at: Self.assetDirectory)
        Task { await runner.unload() }
        status = .notLoaded
    }

    // MARK: Synthesis

    /// Returns 24kHz mono WAV data ready for AVAudioPlayer. Inference happens
    /// off the main thread, so the UI stays responsive while speech generates.
    func synthesize(text: String, voice: String) async throws -> Data {
        #if canImport(Kokoro)
        if await !runner.isLoaded { await prepare() }
        guard case .ready = status else { throw TTSError.notReady }
        return try await runner.synthesizeWAV(text: text, voice: voice)
        #else
        throw TTSError.notAvailable
        #endif
    }

    enum TTSError: LocalizedError {
        case notReady, notAvailable, badURL
        case downloadFailed(String)
        var errorDescription: String? {
            switch self {
            case .notReady: "Kokoro model is not loaded yet"
            case .notAvailable: "Kokoro package is not linked into this build"
            case .badURL: "Invalid download URL"
            case .downloadFailed(let u): "Download failed: \(u)"
            }
        }
    }

    // MARK: Float samples → WAV container
    // `nonisolated` so KokoroRunner can call it from its own actor context.

    nonisolated static func wavData(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let dataSize = samples.count * 2

        func append(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF"); append32(UInt32(36 + dataSize)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(UInt16(channels))
        append32(UInt32(sampleRate)); append32(UInt32(byteRate))
        append16(UInt16(channels * bitsPerSample / 8)); append16(UInt16(bitsPerSample))
        append("data"); append32(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
