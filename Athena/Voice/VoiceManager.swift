import Foundation
import AVFoundation
import Speech
import AppKit

/// Voice I/O: hold-space push-to-talk (on-device STT) + spoken replies (TTS).
///
/// Interaction rules (mirrors Bailongma):
/// - Hold SPACE while not focused in a text field → live transcription; release
///   to send. The reply is spoken aloud.
/// - Typed messages get typed replies (no TTS).
/// - `level` streams a 0…1 amplitude for the live particle-sphere animation,
///   driven by mic input while listening and by synthesizer cadence while speaking.
@MainActor
final class VoiceManager: NSObject, ObservableObject {
    enum VoiceState: Equatable { case idle, listening, speaking }

    enum TTSEngine: String, CaseIterable, Identifiable {
        case system = "System (built-in)"
        case kokoro = "Kokoro (embedded, on-device)"
        case server = "Server (Kokoro / CosyVoice / OpenAI-compatible)"
        var id: String { rawValue }
    }

    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var liveTranscript = ""
    @Published private(set) var level: Float = 0          // 0…1, animation driver
    @Published var voiceReplies = true                    // TTS on voice-initiated turns
    @Published private(set) var permissionDenied = false

    // TTS configuration (persisted)
    @Published var engine: TTSEngine = .system { didSet { persistTTS() } }
    @Published var systemVoiceID: String = "" { didSet { persistTTS() } }
    @Published var speechRate: Double = 0.5 { didSet { persistTTS() } }   // 0.3…0.65
    @Published var serverURL: String = "http://localhost:8880" { didSet { persistTTS() } }
    @Published var serverVoice: String = "af_heart" { didSet { persistTTS() } }
    @Published var kokoroVoice: String = "af_heart" { didSet { persistTTS() } }

    /// Embedded on-device Kokoro engine.
    let kokoro = KokoroEngine()

    /// English voices, best quality first (premium > enhanced > default).
    var availableSystemVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    /// Called with the final transcript when the user releases space.
    var onTranscriptFinal: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var keyMonitor: Any?
    private var levelDecayTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var meterTimer: Timer?
    private var serverFetchTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        installSpaceBarMonitor()
        loadTTS()
    }

    private func loadTTS() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "tts.engine"), let e = TTSEngine(rawValue: raw) { engine = e }
        systemVoiceID = d.string(forKey: "tts.systemVoiceID") ?? ""
        speechRate = d.object(forKey: "tts.rate") as? Double ?? 0.5
        serverURL = d.string(forKey: "tts.serverURL") ?? "http://localhost:8880"
        serverVoice = d.string(forKey: "tts.serverVoice") ?? "af_heart"
        kokoroVoice = d.string(forKey: "tts.kokoroVoice") ?? "af_heart"
    }
    private func persistTTS() {
        let d = UserDefaults.standard
        d.set(engine.rawValue, forKey: "tts.engine")
        d.set(systemVoiceID, forKey: "tts.systemVoiceID")
        d.set(speechRate, forKey: "tts.rate")
        d.set(serverURL, forKey: "tts.serverURL")
        d.set(serverVoice, forKey: "tts.serverVoice")
        d.set(kokoroVoice, forKey: "tts.kokoroVoice")
    }

    // MARK: Permissions

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in self?.permissionDenied = (auth != .authorized) }
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in if !granted { self?.permissionDenied = true } }
        }
    }

    // MARK: Push-to-talk (hold space)

    private func installSpaceBarMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.keyCode == 49 else { return event } // 49 = space
            // If the user is mid-sentence in a text field, space types a space.
            // An EMPTY focused field still allows push-to-talk.
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
               !tv.string.isEmpty, self.state != .listening {
                return event
            }
            if event.type == .keyDown, !event.isARepeat, self.state != .listening {
                self.startListening()
                return nil
            }
            if event.type == .keyUp, self.state == .listening {
                self.stopListeningAndSend()
                return nil
            }
            return self.state == .listening ? nil : event
        }
    }

    func startListening() {
        guard state != .listening, let recognizer, recognizer.isAvailable else { return }
        stopSpeaking()
        // Fully reset any previous session — a half-torn-down engine/recognizer
        // is what made subsequent push-to-talk attempts silently fail.
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        liveTranscript = ""
        state = .listening

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true // privacy: local STT
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let rms = Self.rmsLevel(buffer)
            Task { @MainActor in self?.level = rms }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            Task { @MainActor in self?.liveTranscript = result.bestTranscription.formattedString }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            NSLog("[voice] audio engine start failed: %@", error.localizedDescription)
            state = .idle
        }
    }

    func stopListeningAndSend() {
        guard state == .listening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        state = .idle
        level = 0

        // Give the recognizer a beat to deliver the final partial, then send.
        let transcript = liveTranscript
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            let final = self.liveTranscript.isEmpty ? transcript : self.liveTranscript
            self.liveTranscript = ""
            if !final.isEmpty { self.onTranscriptFinal?(final) }
        }
    }

    // MARK: Text-to-speech

    func speak(_ text: String) {
        guard voiceReplies, !text.isEmpty else { return }
        speakNow(text)
    }

    /// Preview/testing entry point — ignores the voiceReplies toggle.
    func speakNow(_ text: String) {
        stopSpeaking()
        switch engine {
        case .system: speakSystem(text)
        case .kokoro: speakViaKokoro(text)
        case .server: speakViaServer(text)
        }
    }

    /// Embedded on-device Kokoro.
    private func speakViaKokoro(_ text: String) {
        state = .speaking
        serverFetchTask = Task { [kokoroVoice] in
            do {
                let wav = try await self.kokoro.synthesize(text: text, voice: kokoroVoice)
                guard !Task.isCancelled, self.state == .speaking else { return }
                try self.playAudio(wav)
            } catch {
                NSLog("[voice] Kokoro failed (%@) — falling back to system voice",
                      error.localizedDescription)
                guard !Task.isCancelled else { return }
                self.speakSystem(text)
            }
        }
    }

    private func speakSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(speechRate)
        if !systemVoiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: systemVoiceID) {
            utterance.voice = v
        }
        state = .speaking
        synthesizer.speak(utterance)
    }

    /// Kokoro (kokoro-fastapi) or any OpenAI-compatible /v1/audio/speech server.
    private func speakViaServer(_ text: String) {
        state = .speaking
        serverFetchTask = Task { [serverURL, serverVoice] in
            do {
                guard let url = URL(string: serverURL + "/v1/audio/speech") else {
                    throw URLError(.badURL)
                }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "kokoro", "voice": serverVoice,
                    "input": text, "response_format": "mp3",
                ])
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                guard !Task.isCancelled, self.state == .speaking else { return }
                try self.playAudio(data)
            } catch {
                NSLog("[voice] server TTS failed (%@) — falling back to system voice",
                      error.localizedDescription)
                guard !Task.isCancelled else { return }
                self.speakSystem(text)
            }
        }
    }

    private func playAudio(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.isMeteringEnabled = true
        audioPlayer = player
        player.play()
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.audioPlayer, p.isPlaying else { return }
                p.updateMeters()
                // averagePower is dB (-160…0) → 0…1
                let db = p.averagePower(forChannel: 0)
                self.level = max(0, min(1, (db + 40) / 40))
            }
        }
    }

    func stopSpeaking() {
        serverFetchTask?.cancel()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audioPlayer?.stop()
        audioPlayer = nil
        meterTimer?.invalidate()
        if state == .speaking { state = .idle; level = 0 }
    }

    // MARK: Level helpers

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        // Map to a lively 0…1 range.
        return min(1, rms * 12)
    }

    private func pulseOutputLevel() {
        // Approximate speech energy while the synthesizer talks.
        level = Float.random(in: 0.35...0.9)
        levelDecayTimer?.invalidate()
        levelDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            Task { @MainActor in if self?.state == .speaking { self?.level = Float.random(in: 0.2...0.5) } }
        }
    }
}

extension VoiceManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.meterTimer?.invalidate()
            self.audioPlayer = nil
            if self.state == .speaking { self.state = .idle; self.level = 0 }
        }
    }
}

extension VoiceManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.pulseOutputLevel() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.state == .speaking { self.state = .idle; self.level = 0 }
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.state == .speaking { self.state = .idle; self.level = 0 }
        }
    }
}
