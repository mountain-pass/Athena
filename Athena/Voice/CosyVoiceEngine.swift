import Foundation
import AVFoundation

#if canImport(CosyVoiceTTS)
import CosyVoiceTTS
#endif

/// CosyVoice 3 — on-device streaming TTS with **emotion tags** and voice
/// cloning (soniqo/speech-swift, MLX backend, Apple Silicon).
///
/// Weights download from HuggingFace on first use into
/// `~/Library/Caches/qwen3-speech/`. Far larger than Kokoro (1.4–2.1 GB vs
/// 330 MB) but much more expressive: inline `(happy)` / `(whispers)` tags let
/// the agent colour its own delivery.
///
/// ── ADAPTER NOTE ─────────────────────────────────────────────────────────
/// Model type/method names are version-specific. Everything that touches the
/// package lives in `CosyVoiceRunner` below — if the build breaks, fix only
/// that actor against https://soniqo.audio/guides/cosyvoice
/// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class CosyVoiceEngine: ObservableObject {

    enum Variant: String, CaseIterable, Identifiable {
        case fourBit = "4-bit (~1.2 GB, fastest)"
        case eightBit = "8-bit (~1.4 GB, balanced)"
        case eightBitFull = "8-bit full (~1.6 GB)"
        case bf16 = "bf16 (~2.1 GB, best quality)"
        var id: String { rawValue }

        /// HuggingFace repo for this bundle.
        var modelID: String {
            switch self {
            case .fourBit: "aufklarer/CosyVoice3-0.5B-MLX-4bit"
            case .eightBit: "aufklarer/CosyVoice3-0.5B-MLX-8bit"
            case .eightBitFull: "aufklarer/CosyVoice3-0.5B-MLX-8bit-full"
            case .bf16: "aufklarer/CosyVoice3-0.5B-MLX-bf16"
            }
        }
    }

    enum Status: Equatable {
        case notLoaded
        case downloading(Double, String)   // fraction, detail
        case loading
        case ready
        case unavailable(String)

        var label: String {
            switch self {
            case .notLoaded: "Not loaded — first use downloads the model (1.2–2.1 GB)"
            case .downloading(let p, let detail):
                detail.isEmpty ? "Downloading… \(Int(p * 100))%"
                               : "Downloading \(detail) — \(Int(p * 100))%"
            case .loading: "Loading model into memory…"
            case .ready: "Ready — running on-device"
            case .unavailable(let why): "Unavailable: \(why)"
            }
        }
        var isBusy: Bool {
            switch self {
            case .downloading, .loading: true
            default: false
            }
        }
    }

    @Published private(set) var status: Status = .notLoaded
    /// Non-nil after a failure so the UI can offer a retry.
    @Published private(set) var lastFailure: String?

    /// The 8 built-in emotion tags. The agent can emit these inline and
    /// CosyVoice will act on them; unknown tags pass through as freeform
    /// instructions, e.g. "(Speak like a pirate)".
    static let emotions = ["happy", "excited", "sad", "angry",
                           "whispers", "laughs", "calm", "surprised", "serious"]

    var isAvailable: Bool {
        #if canImport(CosyVoiceTTS)
        return true
        #else
        return false
        #endif
    }

    /// Model weights cache used by speech-swift.
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech", isDirectory: true)
    }

    var isDownloaded: Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: Self.cacheDirectory.path) else { return false }
        return contents.contains { $0.lowercased().contains("cosyvoice") }
    }

    private let runner = CosyVoiceRunner()

    func prepare(variant: Variant) async {
        #if canImport(CosyVoiceTTS)
        if await runner.isLoaded { status = .ready; return }
        lastFailure = nil
        status = .downloading(0, "")
        do {
            try await runner.load(modelID: variant.modelID) { [weak self] fraction, detail in
                Task { @MainActor in
                    guard let self else { return }
                    // The library reports 1.0 once weights are fetched; the
                    // remaining wait is loading them into memory.
                    self.status = fraction >= 0.999
                        ? .loading
                        : .downloading(fraction, detail)
                }
            }
            status = .ready
        } catch {
            let message = error.localizedDescription
            lastFailure = message
            status = .unavailable(message)
        }
        #else
        status = .unavailable("speech-swift not linked — run `xcodegen` and build once")
        #endif
    }

    /// Clears the failure and tries again from scratch.
    func retry(variant: Variant) async {
        await runner.unload()
        status = .notLoaded
        lastFailure = nil
        await prepare(variant: variant)
    }

    /// Synthesizes 24kHz WAV. `text` may contain inline emotion tags.
    func synthesize(text: String, variant: Variant, instruction: String?) async throws -> Data {
        #if canImport(CosyVoiceTTS)
        if await !runner.isLoaded { await prepare(variant: variant) }
        guard case .ready = status else { throw TTSError.notReady }
        return try await runner.synthesizeWAV(text: text, instruction: instruction)
        #else
        throw TTSError.notAvailable
        #endif
    }

    func unload() {
        Task { await runner.unload() }
        status = .notLoaded
    }

    enum TTSError: LocalizedError {
        case notReady, notAvailable
        var errorDescription: String? {
            switch self {
            case .notReady: "CosyVoice model is not loaded yet"
            case .notAvailable: "speech-swift is not linked into this build"
            }
        }
    }
}

/// All package-specific calls live here, off the main thread.
///
/// API per soniqo.audio/api — `CosyVoiceTTSModel` conforms to
/// `SpeechGenerationModel`:
///     static func fromPretrained(modelId:cacheDir:offlineMode:progressHandler:)
///     func generate(text:language:) async throws -> [Float]
///     var sampleRate: Int
actor CosyVoiceRunner {
    #if canImport(CosyVoiceTTS)
    private var model: CosyVoiceTTSModel?
    #endif

    var isLoaded: Bool {
        #if canImport(CosyVoiceTTS)
        return model != nil
        #else
        return false
        #endif
    }

    /// `progress` receives (fraction 0…1, human-readable detail).
    func load(modelID: String,
              progress: @escaping @Sendable (Double, String) -> Void) async throws {
        #if canImport(CosyVoiceTTS)
        guard model == nil else { return }
        model = try await CosyVoiceTTSModel.fromPretrained(
            modelId: modelID,
            progressHandler: { fraction, detail in progress(fraction, detail) })
        #endif
    }

    func unload() {
        #if canImport(CosyVoiceTTS)
        model = nil
        #endif
    }

    /// Emotion tags stay inline in `text` — CosyVoice reads the prefix before
    /// `<|endofprompt|>` as a style instruction. A global `instruction` is
    /// prepended when the caller supplies one and the text has no tag.
    func synthesizeWAV(text: String, instruction: String?) async throws -> Data {
        #if canImport(CosyVoiceTTS)
        guard let model else { throw CosyVoiceEngine.TTSError.notReady }

        var prompt = text
        if let instruction, !instruction.isEmpty,
           !text.trimmingCharacters(in: .whitespaces).hasPrefix("(") {
            prompt = "(\(instruction)) \(text)"
        }

        let samples = try await model.generate(text: prompt, language: "english")
        return KokoroEngine.wavData(from: samples, sampleRate: model.sampleRate)
        #else
        throw CosyVoiceEngine.TTSError.notAvailable
        #endif
    }
}
