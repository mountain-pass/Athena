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
        case kokoro = "Kokoro (embedded — fast, 330 MB)"
        case cosyVoice = "CosyVoice 3 (embedded — emotional, 1.2 GB)"
        case server = "Server (OpenAI-compatible endpoint)"
        var id: String { rawValue }
        /// Engines that understand inline `(emotion)` tags.
        var supportsEmotion: Bool { self == .cosyVoice }
    }

    @Published private(set) var state: VoiceState = .idle
    /// Everything said so far this session: finished segments + live partial.
    var liveTranscript: String {
        [committedTranscript, partialTranscript]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    @Published private(set) var committedTranscript = ""
    @Published private(set) var partialTranscript = ""
    @Published private(set) var listeningSince: Date?
    @Published private(set) var level: Float = 0          // 0…1, animation driver
    @Published var voiceReplies = true                    // TTS on voice-initiated turns
    @Published private(set) var permissionDenied = false
    /// Surfaced in the UI when audio can't start.
    @Published var lastError: String?

    // TTS configuration (persisted)
    @Published var engine: TTSEngine = .system { didSet { persistTTS() } }
    @Published var systemVoiceID: String = "" { didSet { persistTTS() } }
    @Published var speechRate: Double = 0.5 { didSet { persistTTS() } }   // 0.3…0.65
    @Published var serverURL: String = "http://localhost:8880" { didSet { persistTTS() } }
    @Published var serverVoice: String = "af_heart" { didSet { persistTTS() } }
    @Published var kokoroVoice: String = "af_heart" { didSet { persistTTS() } }

    /// Embedded on-device Kokoro engine.
    let kokoro = KokoroEngine()
    /// Embedded CosyVoice 3 — emotional / cloning-capable.
    let cosyVoice = CosyVoiceEngine()
    @Published var cosyVariant: CosyVoiceEngine.Variant = .fourBit { didSet { persistTTS() } }
    /// Global style instruction, e.g. "You are a warm, concise assistant."
    @Published var cosyInstruction: String = "" { didSet { persistTTS() } }

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
    private var chunkQueue: [String] = []
    private var prefetchTask: Task<Data?, Never>?
    private var segmentTimer: Timer?
    /// Apple ends a recognition task after ~60s. Rotate before that so long
    /// dictation continues seamlessly.
    private let segmentSeconds: TimeInterval = 45

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
        if let raw = d.string(forKey: "tts.cosyVariant"),
           let v = CosyVoiceEngine.Variant(rawValue: raw) { cosyVariant = v }
        cosyInstruction = d.string(forKey: "tts.cosyInstruction") ?? ""
    }
    private func persistTTS() {
        let d = UserDefaults.standard
        d.set(engine.rawValue, forKey: "tts.engine")
        d.set(systemVoiceID, forKey: "tts.systemVoiceID")
        d.set(speechRate, forKey: "tts.rate")
        d.set(serverURL, forKey: "tts.serverURL")
        d.set(serverVoice, forKey: "tts.serverVoice")
        d.set(kokoroVoice, forKey: "tts.kokoroVoice")
        d.set(cosyVariant.rawValue, forKey: "tts.cosyVariant")
        d.set(cosyInstruction, forKey: "tts.cosyInstruction")
    }

    // MARK: Permissions

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                self?.permissionDenied = (auth == .denied || auth == .restricted)
                if auth == .authorized { self?.lastError = nil }
            }
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                if !granted {
                    self?.permissionDenied = true
                    self?.lastError = "Microphone access denied — enable it in System Settings → Privacy & Security → Microphone."
                }
            }
        }
    }

    /// True when both permissions are in place and listening can start.
    var canListen: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: Push-to-talk (hold space)

    private func installSpaceBarMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }

            // ESC — barge in and shut Athena up.
            if event.keyCode == 53, event.type == .keyDown, self.state == .speaking {
                self.stopSpeaking()
                return nil
            }

            guard event.keyCode == 49 else { return event } // 49 = space
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
        guard state != .listening else { return }

        // Permissions must be granted BEFORE touching the audio engine —
        // otherwise the input node reports a 0-channel format and
        // installTap(onBus:) raises an uncatchable exception (a hard crash).
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard speechAuth == .authorized, micAuth == .authorized else {
            NSLog("[voice] permissions not granted (speech: %d, mic: %d) — requesting",
                  speechAuth.rawValue, micAuth.rawValue)
            permissionDenied = (speechAuth == .denied || micAuth == .denied)
            requestPermissions()
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            NSLog("[voice] recognizer unavailable")
            return
        }

        stopSpeaking()
        // Fully reset any previous session — a half-torn-down engine/recognizer
        // is what made subsequent push-to-talk attempts silently fail.
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        segmentTimer?.invalidate()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        committedTranscript = ""
        partialTranscript = ""
        listeningSince = .now
        state = .listening

        // One long-lived audio tap; recognition requests rotate underneath it,
        // so speech is never dropped mid-sentence.
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Guard against the invalid-format crash: no input device, device in
        // use elsewhere, or permissions revoked mid-session.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("[voice] invalid input format (%.0fHz, %d ch) — aborting",
                  format.sampleRate, format.channelCount)
            state = .idle
            listeningSince = nil
            lastError = "No usable microphone input. Check System Settings → Privacy & Security → Microphone."
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Feed whichever request is current right now.
            self?.recognitionRequest?.append(buffer)
            let rms = Self.rmsLevel(buffer)
            Task { @MainActor in self?.level = rms }
        }

        startSegment()

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            NSLog("[voice] audio engine start failed: %@", error.localizedDescription)
            state = .idle
            listeningSince = nil
        }

        // Rotate before Apple's per-task limit so long dictation keeps going.
        segmentTimer = Timer.scheduledTimer(withTimeInterval: segmentSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rotateSegment() }
        }
    }

    /// Starts a fresh recognition request. Transcription runs on the Speech
    /// framework's own queue — never the main thread.
    private func startSegment() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // privacy: local STT
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result else {
                if let error { NSLog("[voice] recognition: %@", error.localizedDescription) }
                return
            }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self?.partialTranscript = text }
        }
    }

    /// Commits what's been recognized so far and swaps in a new request,
    /// keeping the audio tap alive so the user can talk continuously.
    private func rotateSegment() {
        guard state == .listening else { return }
        let finished = partialTranscript.trimmingCharacters(in: .whitespaces)
        if !finished.isEmpty {
            committedTranscript = committedTranscript.isEmpty
                ? finished
                : committedTranscript + " " + finished
        }
        partialTranscript = ""
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        startSegment()
    }

    /// Seconds spent listening in the current session.
    var listeningElapsed: TimeInterval {
        listeningSince.map { Date().timeIntervalSince($0) } ?? 0
    }

    func stopListeningAndSend() {
        guard state == .listening else { return }
        segmentTimer?.invalidate()
        segmentTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        state = .idle
        level = 0
        listeningSince = nil

        // Give the recognizer a beat to deliver its final partial, then send
        // the whole session (all rotated segments stitched together).
        let snapshot = liveTranscript
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let final = self.liveTranscript.count >= snapshot.count ? self.liveTranscript : snapshot
            self.committedTranscript = ""
            self.partialTranscript = ""
            self.recognitionRequest = nil
            self.recognitionTask = nil
            let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self.onTranscriptFinal?(trimmed) }
        }
    }

    // MARK: Text-to-speech

    func speak(_ text: String) {
        guard voiceReplies, !text.isEmpty else { return }
        speakNow(text)
    }

    /// Sanity ceilings only — long replies ARE spoken in full via the streaming
    /// chunk pipeline (synthesize-ahead while playing). These exist to stop a
    /// runaway payload from queuing hundreds of synthesis jobs.
    static let maxSpeakCharacters = 12_000   // ~15 minutes of speech
    static let maxChunks = 80

    /// Preview/testing entry point — ignores the voiceReplies toggle.
    func speakNow(_ rawText: String) {
        // Refuse machine payloads outright.
        guard !ChatMessage.looksLikeToolNoise(rawText) else {
            NSLog("[voice] refusing to speak tool output (%d chars)", rawText.count)
            return
        }

        var text = Self.speakableText(rawText, keepEmotionTags: engine.supportsEmotion)
        guard !text.isEmpty else { return }

        if text.count > Self.maxSpeakCharacters {
            // Cut at a sentence boundary near the limit.
            let cutoff = text.index(text.startIndex, offsetBy: Self.maxSpeakCharacters)
            let head = String(text[text.startIndex..<cutoff])
            if let lastStop = head.lastIndex(where: { ".!?".contains($0) }) {
                text = String(head[head.startIndex...lastStop])
            } else {
                text = head
            }
            text += " That's the short version — the rest is in the chat."
        }

        stopSpeaking()
        switch engine {
        case .system:
            // AVSpeechSynthesizer already starts almost instantly.
            speakSystem(text)
        case .kokoro, .cosyVoice, .server:
            // Neural engines synthesize a whole request before any audio
            // exists, so long replies would sit silent for seconds. Split
            // into sentence chunks: speak chunk 1 while chunk 2 renders.
            startChunkedPlayback(text)
        }
    }

    // MARK: Streaming speech
    //
    // Waiting for a whole reply before synthesizing is the main source of lag.
    // Instead we start speaking the first complete sentence while the rest of
    // the reply is still arriving from the gateway.

    private var streamConsumedCount = 0
    private var streamActive = false

    func beginStreamingSpeech() {
        guard voiceReplies else { return }
        stopSpeaking()
        streamConsumedCount = 0
        streamActive = true
        state = .speaking          // claim the state so nothing else interrupts
    }

    /// Feed the reply-so-far; any newly completed sentences are queued.
    func appendStreamingSpeech(fullTextSoFar: String) {
        guard streamActive, voiceReplies else { return }
        guard !ChatMessage.looksLikeToolNoise(fullTextSoFar) else { return }

        let clean = Self.speakableText(fullTextSoFar, keepEmotionTags: engine.supportsEmotion)
        guard clean.count > streamConsumedCount else { return }

        // Only take up to the last completed sentence.
        let pending = String(clean.dropFirst(streamConsumedCount))
        guard let lastStop = pending.lastIndex(where: { ".!?".contains($0) }) else { return }
        let ready = String(pending[pending.startIndex...lastStop])
        guard ready.count > 20 else { return }      // wait for something worth saying

        streamConsumedCount += ready.count
        let newChunks = Self.splitIntoChunks(ready, firstChunkTarget: 60)
        chunkQueue.append(contentsOf: newChunks)

        // Kick playback if nothing is currently sounding.
        if audioPlayer == nil, !synthesizer.isSpeaking, prefetchTask == nil {
            Task { await playNextChunk() }
        }
    }

    /// Final flush — speaks whatever's left after the last sentence boundary.
    func endStreamingSpeech(fullText: String) {
        guard streamActive else { return }
        streamActive = false
        guard voiceReplies, !ChatMessage.looksLikeToolNoise(fullText) else {
            if state == .speaking && audioPlayer == nil { state = .idle }
            return
        }
        let clean = Self.speakableText(fullText, keepEmotionTags: engine.supportsEmotion)
        if clean.count > streamConsumedCount {
            let remainder = String(clean.dropFirst(streamConsumedCount))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                chunkQueue.append(contentsOf: Self.splitIntoChunks(remainder))
            }
        }
        if audioPlayer == nil, !synthesizer.isSpeaking, prefetchTask == nil {
            Task { await playNextChunk() }
        }
        if chunkQueue.isEmpty, audioPlayer == nil, state == .speaking { state = .idle }
    }

    // MARK: Chunked playback (low latency + interruptible)

    private func startChunkedPlayback(_ text: String) {
        chunkQueue = Array(Self.splitIntoChunks(text).prefix(Self.maxChunks))
        guard !chunkQueue.isEmpty else { return }
        state = .speaking
        Task { await playNextChunk() }
    }

    private func playNextChunk() async {
        guard state == .speaking else { return }
        guard !chunkQueue.isEmpty else { finishSpeaking(); return }

        let chunk = chunkQueue.removeFirst()
        // Use the audio we rendered ahead of time, if any.
        let data: Data?
        if let task = prefetchTask {
            prefetchTask = nil
            data = await task.value
        } else {
            data = await synthesizeChunk(chunk)
        }

        // Start rendering the next chunk while this one plays.
        if let next = chunkQueue.first {
            prefetchTask = Task { [weak self] in
                await self?.synthesizeChunk(next) ?? nil
            }
        }

        guard state == .speaking, let data else { finishSpeaking(); return }
        do { try playAudio(data) } catch { finishSpeaking() }
    }

    private func synthesizeChunk(_ chunk: String) async -> Data? {
        do {
            switch engine {
            case .kokoro:
                return try await kokoro.synthesize(text: chunk, voice: kokoroVoice)
            case .cosyVoice:
                return try await cosyVoice.synthesize(
                    text: chunk, variant: cosyVariant,
                    instruction: cosyInstruction.isEmpty ? nil : cosyInstruction)
            case .server:
                return try await fetchServerAudio(chunk)
            case .system:
                return nil
            }
        } catch {
            NSLog("[voice] synthesis failed (%@) — falling back to system voice",
                  error.localizedDescription)
            // Speak the remainder with the system voice rather than going silent.
            let remainder = ([chunk] + chunkQueue).joined(separator: " ")
            chunkQueue = []
            speakSystem(remainder)
            return nil
        }
    }

    private func finishSpeaking() {
        prefetchTask?.cancel()
        prefetchTask = nil
        chunkQueue = []
        if state == .speaking { state = .idle; level = 0 }
    }

    /// Strips markdown, emoji and other artifacts that sound wrong when read
    /// aloud. Belt and braces alongside the agent-side voice directive.
    /// - Parameter keepEmotionTags: CosyVoice acts on inline `(happy)` /
    ///   `(whispers)` tags, so they must survive; other engines would read
    ///   them aloud, so they're removed.
    static func speakableText(_ raw: String, keepEmotionTags: Bool = false) -> String {
        // Regex over a huge string is slow — bound the input first.
        var s = raw.count > 20_000 ? String(raw.prefix(20_000)) : raw

        if !keepEmotionTags {
            let tags = CosyVoiceEngine.emotions.joined(separator: "|")
            s = s.replacingOccurrences(of: "\\((\(tags))\\)", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }

        func replace(_ pattern: String, _ with: String) {
            s = s.replacingOccurrences(of: pattern, with: with,
                                       options: [.regularExpression])
        }

        replace("```[\\s\\S]*?```", " (code omitted) ")   // fenced code blocks
        replace("`([^`]*)`", "$1")                        // inline code
        replace("!\\[[^\\]]*\\]\\([^)]*\\)", " ")         // images
        replace("\\[([^\\]]+)\\]\\([^)]*\\)", "$1")       // links → link text
        replace("^#{1,6}\\s*", "")                        // headings
        replace("(?m)^\\s*[-*+]\\s+", "")                 // bullets
        replace("(?m)^\\s*\\d+\\.\\s+", "")               // numbered lists
        replace("(?m)^\\s*>\\s?", "")                     // block quotes
        replace("(?m)^\\s*[-–—_*]{3,}\\s*$", "")          // horizontal rules
        replace("\\*\\*([^*]+)\\*\\*", "$1")              // bold
        replace("\\*([^*]+)\\*", "$1")                    // italic
        replace("__([^_]+)__", "$1")
        replace("https?://\\S+", "")                      // bare URLs
        replace("[ \\t]{2,}", " ")

        // Drop emoji and pictographs.
        s = s.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
              && scalar.value > 0x238C)
        }.map(Character.init).reduce(into: "") { $0.append($1) }

        // Collapse blank lines into sentence breaks.
        s = s.replacingOccurrences(of: "\n{2,}", with: ". ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits on sentence boundaries, keeping chunks small enough that the
    /// first one renders fast but large enough to sound natural.
    static func splitIntoChunks(_ text: String, target: Int = 180,
                                firstChunkTarget: Int = 90) -> [String] {
        let sentences = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            // Keep the first chunk short so audio starts as soon as possible.
            let limit = chunks.isEmpty ? firstChunkTarget : target
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count < limit {
                current += ". " + sentence
            } else {
                chunks.append(current + ".")
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current + ".") }
        return chunks
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

    /// kokoro-fastapi / CosyVoice / any OpenAI-compatible /v1/audio/speech.
    private func fetchServerAudio(_ text: String) async throws -> Data {
        guard let url = URL(string: serverURL + "/v1/audio/speech") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "kokoro", "voice": serverVoice,
            "input": text, "response_format": "mp3",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
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

    /// Stops speech immediately — ESC, the Stop button, or starting to talk.
    func stopSpeaking() {
        serverFetchTask?.cancel()
        prefetchTask?.cancel()
        prefetchTask = nil
        chunkQueue = []
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audioPlayer?.stop()
        audioPlayer = nil
        meterTimer?.invalidate()
        if state == .speaking { state = .idle; level = 0 }
    }

    var isSpeaking: Bool { state == .speaking }

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
            // Continue with the next sentence chunk, or finish.
            await self.playNextChunk()
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
