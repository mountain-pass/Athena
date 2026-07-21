import Foundation

#if canImport(Kokoro)
import Kokoro
#endif

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
        let model = try KModel(configURL: configURL, weightsURL: weightsURL)
        let voices = VoiceLoader(baseDirectory: voicesDirectory, enableDownload: true)
        pipeline = KPipeline(model: model, voices: voices)
        #endif
    }

    func unload() {
        #if canImport(Kokoro)
        pipeline = nil
        #endif
    }

    /// Runs inference AND WAV encoding inside the actor — both are heavy loops
    /// that must stay off the main thread.
    func synthesizeWAV(text: String, voice: String) throws -> Data {
        #if canImport(Kokoro)
        guard let pipeline else { throw KokoroEngine.TTSError.notReady }
        let samples = try pipeline.synthesize(text: text, voice: voice).audio
        return KokoroEngine.wavData(from: samples, sampleRate: 24_000)
        #else
        throw KokoroEngine.TTSError.notAvailable
        #endif
    }
}
