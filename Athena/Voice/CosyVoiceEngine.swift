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
        // NOTE: 4-bit exists on HuggingFace but this runtime rejects it —
        // "LLM bundles must be 8-bit quantized or 16-bit/bf16 plain Linear".
        case eightBit = "8-bit (~1.4 GB, recommended)"
        case eightBitFull = "8-bit full (~1.6 GB)"
        case bf16 = "bf16 (~2.1 GB, best quality)"
        var id: String { rawValue }

        /// HuggingFace repo for this bundle.
        var modelID: String {
            switch self {
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
    /// Called when an unsupported variant forces a switch, so the picker
    /// reflects what's actually loaded.
    var onVariantFallback: ((Variant) -> Void)?

    /// Reference clip for zero-shot cloning. CosyVoice has no built-in voice
    /// catalogue — you pick a voice by giving it a few seconds of audio.
    @Published var voiceSamplePath: String = UserDefaults.standard
        .string(forKey: "tts.cosyVoiceSample") ?? "" {
        didSet { UserDefaults.standard.set(voiceSamplePath, forKey: "tts.cosyVoiceSample") }
    }
    @Published var voiceSampleLabel: String = UserDefaults.standard
        .string(forKey: "tts.cosyVoiceLabel") ?? "" {
        didSet { UserDefaults.standard.set(voiceSampleLabel, forKey: "tts.cosyVoiceLabel") }
    }
    @Published private(set) var buildingReference = false

    var voiceSampleURL: URL? {
        voiceSamplePath.isEmpty ? nil : URL(fileURLWithPath: voiceSamplePath)
    }

    /// Where generated reference clips live.
    static var referenceDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Athena/VoiceRefs", isDirectory: true)
    }

    /// Borrows a Kokoro voice as a CosyVoice reference: synthesize a sample
    /// with Kokoro, then clone it. This is how soniqo's own docs demo cloning,
    /// and it gives CosyVoice a usable voice picker.
    /// Step-by-step status so the user can see what's happening — this takes
    /// a while and previously looked like nothing was going on.
    @Published private(set) var referenceStatus: String?

    func buildReference(fromKokoroVoice voiceID: String, label: String,
                        using kokoro: KokoroEngine) async {
        buildingReference = true
        lastFailure = nil
        defer { buildingReference = false; referenceStatus = nil }

        // Reuse a clip we already generated for this voice.
        let url = Self.referenceDirectory.appendingPathComponent("\(voiceID).wav")
        if FileManager.default.fileExists(atPath: url.path) {
            voiceSamplePath = url.path
            voiceSampleLabel = label
            referenceStatus = "Using saved clip"
            return
        }

        // Kokoro has to be present to generate the sample — do it here rather
        // than failing silently.
        if case .ready = kokoro.status {} else {
            referenceStatus = kokoro.isDownloaded
                ? "Loading Kokoro model…"
                : "Downloading Kokoro model (~330 MB)…"
            await kokoro.prepare()
        }
        guard case .ready = kokoro.status else {
            lastFailure = """
                Kokoro isn't available, so this voice can't be cloned. \
                Switch Engine to Kokoro, download the model, then come back — \
                or record your own clip instead.
                """
            return
        }

        do {
            referenceStatus = "Synthesizing sample in \(label)…"
            let sampleText = """
                The quick brown fox jumps over the lazy dog. \
                I can help you with your schedule, your news, and anything else you need today.
                """
            let wav = try await kokoro.synthesize(text: sampleText, voice: voiceID)
            guard wav.count > 1024 else {
                lastFailure = "Kokoro produced no audio for \(label)."
                return
            }
            referenceStatus = "Saving reference clip…"
            try FileManager.default.createDirectory(at: Self.referenceDirectory,
                                                    withIntermediateDirectories: true)
            try wav.write(to: url)
            voiceSamplePath = url.path
            voiceSampleLabel = label
            referenceStatus = "Ready — CosyVoice will clone this voice"
        } catch {
            lastFailure = "Could not build reference: \(error.localizedDescription)"
        }
    }

    func clearReference() {
        voiceSamplePath = ""
        voiceSampleLabel = ""
    }

    /// Drops the loaded model (used when the variant changes).
    func unload() {
        Task { await runner.unload() }
        status = .notLoaded
    }

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

    /// Shared representation so every model download renders identically.
    var phase: ModelPhase {
        switch status {
        case .notLoaded:
            return isDownloaded
                ? .loading("Downloaded — not yet loaded")
                : .absent("Not downloaded — spoken replies will use the system voice")
        case .downloading(let f, _): return .downloading(f)
        case .loading:               return .loading(status.label)
        case .ready:                 return .ready(status.label)
        case .unavailable(let why):  return .failed(why)
        }
    }

    /// Extra text under the progress bar (which file, how far).
    var progressDetail: String? {
        if case .downloading(_, let detail) = status, !detail.isEmpty { return detail }
        return nil
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
            // Unsupported quantisation → fall back to 8-bit automatically
            // rather than leaving the user stuck on a dead setting.
            if message.contains("8-bit quantized") || message.contains("plain Linear"),
               variant != .eightBit {
                NSLog("[cosyvoice] %@ unsupported — retrying with 8-bit", variant.rawValue)
                onVariantFallback?(.eightBit)
                await runner.unload()
                await prepare(variant: .eightBit)
                return
            }
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

    /// Synthesizes 24kHz WAV. `text` may contain inline emotion tags, and the
    /// reference clip (if set) determines the voice.
    func synthesize(text: String, variant: Variant, instruction: String?) async throws -> Data {
        #if canImport(CosyVoiceTTS)
        if await !runner.isLoaded { await prepare(variant: variant) }
        guard case .ready = status else { throw TTSError.notReady }
        return try await runner.synthesizeWAV(text: text,
                                              instruction: instruction,
                                              voiceSample: voiceSampleURL)
        #else
        throw TTSError.notAvailable
        #endif
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
/// Voice cloning (per soniqo.audio/guides/voice-cloning) is a two-step flow:
///   1. `CamPlusPlusSpeaker.embed(audio:sampleRate:)` → 192-dim embedding
///   2. `model.synthesize(text:instruction:speakerEmbedding:)`
/// The embedding is cached per reference clip — extracting it runs a CoreML
/// pass on the Neural Engine and shouldn't repeat for every sentence chunk.
actor CosyVoiceRunner {
    #if canImport(CosyVoiceTTS)
    private var model: CosyVoiceTTSModel?
    private var speaker: CamPlusPlusSpeaker?
    private var cachedEmbedding: [Float]?
    private var cachedSamplePath: String?
    #endif

    var isLoaded: Bool {
        #if canImport(CosyVoiceTTS)
        return model != nil
        #else
        return false
        #endif
    }

    func load(modelID: String,
              progress: @escaping @Sendable (Double, String) -> Void) async throws {
        #if canImport(CosyVoiceTTS)
        guard model == nil else { return }
        MLXMemory.configure()
        model = try await CosyVoiceTTSModel.fromPretrained(
            modelId: modelID,
            progressHandler: { fraction, detail in progress(fraction, detail) })
        #endif
    }

    func unload() {
        #if canImport(CosyVoiceTTS)
        model = nil
        speaker = nil
        cachedEmbedding = nil
        cachedSamplePath = nil
        MLXMemory.flush()
        #endif
    }

    /// Extracts (and caches) the speaker embedding for a reference clip.
    private func embedding(for url: URL) async throws -> [Float]? {
        #if canImport(CosyVoiceTTS)
        if cachedSamplePath == url.path, let cachedEmbedding { return cachedEmbedding }

        if speaker == nil {
            // ~14 MB CoreML model, downloaded on first use.
            speaker = try await CamPlusPlusSpeaker.fromPretrained()
        }
        guard let speaker,
              let (samples, sampleRate) = AudioSampleLoader.load(url: url) else { return nil }

        let embedding = try speaker.embed(audio: samples, sampleRate: sampleRate)
        cachedEmbedding = embedding
        cachedSamplePath = url.path
        return embedding
        #else
        return nil
        #endif
    }

    /// Emotion tags stay inline in `text`; `instruction` is the global style.
    func synthesizeWAV(text: String, instruction: String?,
                       voiceSample: URL? = nil) async throws -> Data {
        #if canImport(CosyVoiceTTS)
        guard let model else { throw CosyVoiceEngine.TTSError.notReady }
        defer { MLXMemory.flush() }

        // Cloned voice path.
        if let voiceSample, FileManager.default.fileExists(atPath: voiceSample.path),
           let embedding = try? await embedding(for: voiceSample) {
            let samples: [Float]
            if let instruction, !instruction.isEmpty {
                samples = model.synthesize(text: text,
                                           instruction: instruction,
                                           speakerEmbedding: embedding)
            } else {
                samples = model.synthesize(text: text, speakerEmbedding: embedding)
            }
            return KokoroEngine.wavData(from: samples, sampleRate: model.sampleRate)
        }

        // Default voice — instruction rides inline as a leading tag.
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

/// Decodes an audio file into mono Float samples for the speaker encoder.
enum AudioSampleLoader {
    static func load(url: URL) -> (samples: [Float], sampleRate: Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData else { return nil }

        let count = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)

        if channels == 1 {
            mono = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        } else {
            // Downmix — the encoder expects a single speaker channel.
            for frame in 0..<count {
                var sum: Float = 0
                for channel in 0..<channels { sum += channelData[channel][frame] }
                mono[frame] = sum / Float(channels)
            }
        }
        return (mono, Int(format.sampleRate))
    }
}
