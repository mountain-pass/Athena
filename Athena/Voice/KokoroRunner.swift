import Foundation

#if canImport(Kokoro)
import Kokoro
#endif

#if canImport(MLX)
import MLX
#endif

/// MLX keeps a GPU buffer cache that, left alone, grows without bound across
/// repeated inference — which is how a 330 MB model ends up holding tens of
/// gigabytes. We cap it and flush after each synthesis.
enum MLXMemory {
    /// Plenty for an 82M model; anything larger is just retained scratch.
    static let cacheLimitBytes = 192 * 1024 * 1024

    static func configure() {
        #if canImport(MLX)
        MLX.GPU.set(cacheLimit: cacheLimitBytes)
        #endif
    }

    static func flush() {
        #if canImport(MLX)
        MLX.GPU.clearCache()
        #endif
    }

    /// Active + cached bytes, for logging.
    static var footprint: String {
        #if canImport(MLX)
        let snapshot = MLX.GPU.snapshot()
        let mb = { (bytes: Int) in String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        return "active \(mb(snapshot.activeMemory)), cache \(mb(snapshot.cacheMemory))"
        #else
        return "n/a"
        #endif
    }
}

/// Off-main-thread home for Kokoro model loading and inference.
///
/// Both operations are heavy (model load can take seconds; synthesis is a full
/// neural forward pass). Running them on the main actor froze the UI — progress
/// bars stopped updating and the app looked hung. Keeping them inside this
/// actor means the interface stays live while speech is generated.
actor KokoroRunner {

    #if canImport(Kokoro)
    private var pipeline: KPipeline?
    #endif

    var isLoaded: Bool {
        #if canImport(Kokoro)
        return pipeline != nil
        #else
        return false
        #endif
    }

    func load(configURL: URL, weightsURL: URL, voicesDirectory: URL) throws {
        #if canImport(Kokoro)
        guard pipeline == nil else { return }
        MLXMemory.configure()
        let model = try KModel(configURL: configURL, weightsURL: weightsURL)
        let voices = VoiceLoader(baseDirectory: voicesDirectory, enableDownload: true)
        pipeline = KPipeline(model: model, voices: voices)
        NSLog("[kokoro] loaded — %@", MLXMemory.footprint)
        #endif
    }

    func unload() {
        #if canImport(Kokoro)
        pipeline = nil
        MLXMemory.flush()
        #endif
    }

    /// Runs inference AND WAV encoding inside the actor — both are heavy loops
    /// that must stay off the main thread.
    func synthesizeWAV(text: String, voice: String) throws -> Data {
        #if canImport(Kokoro)
        guard let pipeline else { throw KokoroEngine.TTSError.notReady }
        defer {
            // Release scratch buffers immediately — without this the cache
            // grows with every sentence and never comes back down.
            MLXMemory.flush()
        }
        let samples = try pipeline.synthesize(text: text, voice: voice).audio
        return KokoroEngine.wavData(from: samples, sampleRate: 24_000)
        #else
        throw KokoroEngine.TTSError.notAvailable
        #endif
    }
}
