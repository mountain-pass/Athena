import Foundation
import AVFoundation
import Speech
import AppKit

/// Thread-safe buffer counter written from the real-time audio thread and
/// read from the main actor. The mic tap fires on CoreAudio's own thread, so
/// the ONLY truthful "is audio flowing" signal is one incremented right there,
/// synchronously — not a value updated via a main-actor hop that can lag or be
/// starved. Getting this wrong is what made a working mic report "no audio".
final class AudioFlowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func reset() { lock.lock(); value = 0; lock.unlock() }
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// One recognition segment's text.
///
/// Deliberately NOT main-actor isolated: Speech delivers callbacks on its own
/// queue and we write synchronously there, which preserves the order the
/// recognizer produced hypotheses in. Hopping to the main actor per callback
/// spawns unstructured Tasks that can run out of order, so a stale (shorter)
/// hypothesis lands last and silently truncates the sentence.
final class TranscriptSegment: @unchecked Sendable {
    let id: Int
    private let lock = NSLock()
    private var storage = ""
    private var sealed = false

    init(id: Int) { self.id = id }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Applies a new hypothesis. Growth is MONOTONIC: a shorter string is
    /// never accepted, final or not.
    ///
    /// Finals are emphatically not trustworthy here. After endAudio() the
    /// recognizer routinely emits a final result with an empty (or badly
    /// truncated) transcription — a lifecycle marker rather than a better
    /// answer. Taking it at face value wipes the entire utterance, which is
    /// what made a correct on-screen transcript send as nothing at all.
    func update(_ new: String, isFinal: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !sealed else { return }
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= storage.count { storage = trimmed }
        if isFinal { sealed = true }
    }

    /// Freezes the box so nothing from the retired task can change it.
    @discardableResult
    func seal() -> String {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        return storage
    }
}

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

    /// Which recognizer transcribes push-to-talk audio.
    enum STTEngine: String, CaseIterable, Identifiable {
        case parakeet = "Parakeet (embedded — accurate, 600 MB)"
        case apple = "Apple (built-in — fast, no download)"
        var id: String { rawValue }
    }

    @Published private(set) var state: VoiceState = .idle
    /// Everything said so far this session: committed segments + the live one.
    /// Published rather than computed so the UI updates from one source.
    @Published private(set) var liveTranscript = ""

    /// Default to Parakeet: Apple's recognizer misrecognises long-form speech
    /// and goes dormant on pauses. Apple stays available as a zero-download
    /// fallback.
    @Published var sttEngine: STTEngine = .parakeet {
        didSet {
            guard oldValue != sttEngine else { return }
            UserDefaults.standard.set(sttEngine.rawValue, forKey: "stt.engine")
            if sttEngine == .parakeet {
                parakeet.warmUp()
            } else {
                // Ask now, at the point the choice is made and the prompt has
                // obvious context — not on first launch out of nowhere.
                requestSpeechPermission()
            }
        }
    }

    let parakeet = ParakeetSTT()

    /// Raw 16kHz audio for the whole hold-SPACE session. With a batch model
    /// this replaces all of the segment/rotation machinery below.
    private let sampleBuffer = AudioSampleBuffer()
    /// True while a preview transcription is running (they must not overlap).
    private var previewRunning = false
    private var previewTimer: Timer?
    /// Set when SPACE is released so a late preview can't clobber the result.
    private var previewSuppressed = false
    /// True during the final pass after release — the UI shows "transcribing"
    /// rather than pretending it's still listening.
    @Published private(set) var transcribing = false
    /// Held so the user can abort a slow transcription (ESC or the Stop button).
    private var transcriptionTask: Task<Void, Never>?

    /// Abandons an in-flight transcription and discards the recording.
    /// Cancellation lands between chunks, so a long recording stops promptly
    /// even though a single CoreML inference can't be interrupted.
    func cancelTranscription() {
        guard transcribing else { return }
        NSLog("[voice] transcription cancelled")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcribing = false
        sampleBuffer.reset()
        resetTranscript(reason: "cancelled")
        state = .idle
        finalizing = false
        level = 0
    }

    // MARK: Transcript accumulation
    //
    // While SPACE is held the transcript is APPEND-ONLY. Apple's recognizer
    // finalizes a task after a few seconds of silence — that is a *segment
    // boundary*, not the end of the user's thought, so we commit and start a
    // new task underneath the same audio tap.
    //
    // The subtle failure this design fixes: a retired recognition task keeps
    // delivering callbacks after cancel(). When every segment wrote into one
    // shared `partialTranscript`, a late callback from the old task could
    // clobber it — and because the commit step *read* from that same shared
    // property, whole sentences vanished at exactly the moment the user
    // paused. Now each segment owns its own text box, so a stale callback can
    // only ever write to a box nobody reads, and committing takes the text
    // from the box that produced it.
    //
    // `committedSegments` is emptied in exactly TWO places: startListening()
    // (a brand-new session) and after the text is handed to the chat on
    // SPACE release. Nothing else may clear it.

    private var committedSegments: [String] = []
    private var liveSegment: TranscriptSegment?

    /// Recomputes the published transcript from the append-only parts.
    private func refreshTranscript() {
        let live = liveSegment?.text ?? ""
        liveTranscript = (committedSegments + [live])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The only sanctioned way to discard accumulated speech.
    private func resetTranscript(reason: String) {
        NSLog("[voice] transcript reset (%@) — discarding %d chars",
              reason, liveTranscript.count)
        committedSegments = []
        liveSegment = nil
        liveTranscript = ""
    }
    @Published private(set) var listeningSince: Date?
    @Published private(set) var level: Float = 0          // 0…1, animation driver
    /// TTS on voice-initiated turns. Persisted like every other voice setting —
    /// this one was being reset to `true` on every launch.
    @Published var voiceReplies = true { didSet { persistTTS() } }
    @Published private(set) var permissionDenied = false
    /// Surfaced in the UI when audio can't start.
    @Published var lastError: String?

    // TTS configuration (persisted)
    @Published var engine: TTSEngine = .system {
        didSet {
            persistTTS()
            guard oldValue != engine else { return }
            warmCurrentEngine()
        }
    }
    @Published var systemVoiceID: String = "" { didSet { persistTTS() } }
    @Published var speechRate: Double = 0.5 { didSet { persistTTS() } }   // 0.3…0.65
    @Published var serverURL: String = "http://localhost:8880" { didSet { persistTTS() } }
    @Published var serverVoice: String = "af_heart" { didSet { persistTTS() } }
    @Published var kokoroVoice: String = "af_heart" {
        didSet {
            persistTTS()
            // Warm the newly chosen voice so the next reply doesn't stall on
            // a first-use download + MLX compile.
            guard oldValue != kokoroVoice, engine == .kokoro else { return }
            warmCurrentEngine()
        }
    }

    /// Preloads whatever the current engine needs so speech starts instantly.
    /// Safe to call repeatedly — each engine no-ops once warm.
    func warmCurrentEngine() {
        switch engine {
        case .kokoro:
            guard kokoro.isDownloaded else { return }
            let voice = kokoroVoice
            Task { await kokoro.warmUp(voice: voice) }
        case .cosyVoice:
            guard cosyVoice.isDownloaded else { return }
            let variant = cosyVariant
            Task { await cosyVoice.prepare(variant: variant) }
        default:
            break
        }
    }

    /// Embedded on-device Kokoro engine.
    let kokoro = KokoroEngine()
    /// Embedded CosyVoice 3 — emotional / cloning-capable.
    let cosyVoice = CosyVoiceEngine()
    @Published var cosyVariant: CosyVoiceEngine.Variant = .eightBit {
        didSet {
            persistTTS()
            // A loaded model belongs to the OLD variant — drop it so the next
            // utterance loads the one that's now selected.
            guard oldValue != cosyVariant, !suppressVariantReload else { return }
            cosyVoice.unload()
        }
    }
    /// Set while we're applying a runtime-forced fallback, to avoid a loop.
    private var suppressVariantReload = false
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

    // ONE engine for the whole app lifetime. Creating a new engine per session
    // was the cause of the "error 35 / resource busy" failures: each new engine
    // tried to grab the input device before the previous engine's async device
    // teardown had finished, so the mic was still held and the tap never fired.
    // A single engine acquires the device once and re-uses it cleanly.
    private let audioEngine = AVAudioEngine()
    /// Guards against an endless start→no-audio→restart loop.
    private var didRetryEngineStart = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var keyMonitor: Any?
    private var levelDecayTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var meterTimer: Timer?
    private var serverFetchTask: Task<Void, Never>?
    private var segmentTimer: Timer?
    /// Apple ends a recognition task after ~60s. Rotate before that so long
    /// dictation continues seamlessly.
    private let segmentSeconds: TimeInterval = 45

    override init() {
        super.init()
        synthesizer.delegate = self
        installSpaceBarMonitor()
        loadTTS()
        loadSTT()
        // Explicitly warm on launch. Relying on the `engine` didSet isn't
        // enough: it's guarded by `oldValue != engine`, so a saved engine that
        // matches the default never fires it and the model stayed cold until
        // the first reply. Both warmers are no-ops unless the weights are
        // already on disk — neither will start a download.
        warmCurrentEngine()
        // Keep the picker honest if the runtime rejects a variant.
        cosyVoice.onVariantFallback = { [weak self] variant in
            Task { @MainActor in
                guard let self else { return }
                self.suppressVariantReload = true
                self.cosyVariant = variant
                self.suppressVariantReload = false
            }
        }
    }

    private func loadSTT() {
        if let raw = UserDefaults.standard.string(forKey: "stt.engine"),
           let e = STTEngine(rawValue: raw) {
            sttEngine = e
        }
        NSLog("[voice] restored settings — STT: %@, TTS: %@, spoken replies: %@",
              sttEngine.rawValue, engine.rawValue, voiceReplies ? "on" : "off")
        // Loads the model into memory if it's already on disk, so the first
        // dictation isn't a cold start. Never downloads — see warmUp().
        if sttEngine == .parakeet { parakeet.warmUp() }
    }

    private func loadTTS() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "tts.engine"), let e = TTSEngine(rawValue: raw) { engine = e }
        systemVoiceID = d.string(forKey: "tts.systemVoiceID") ?? ""
        speechRate = d.object(forKey: "tts.rate") as? Double ?? 0.5
        serverURL = d.string(forKey: "tts.serverURL") ?? "http://localhost:8880"
        serverVoice = d.string(forKey: "tts.serverVoice") ?? "af_heart"
        kokoroVoice = d.string(forKey: "tts.kokoroVoice") ?? "af_heart"
        // A stored 4-bit selection no longer exists — fall back cleanly.
        if let raw = d.string(forKey: "tts.cosyVariant") {
            cosyVariant = CosyVoiceEngine.Variant(rawValue: raw) ?? .eightBit
        }
        cosyInstruction = d.string(forKey: "tts.cosyInstruction") ?? ""
        // `object(forKey:)` rather than `bool(forKey:)` — the latter returns
        // false for a missing key, which would silently flip the default.
        voiceReplies = d.object(forKey: "tts.voiceReplies") as? Bool ?? true
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
        d.set(voiceReplies, forKey: "tts.voiceReplies")
    }

    // MARK: Permissions

    /// Requests only what the *current* engine actually needs.
    ///
    /// Parakeet transcribes locally and never touches the Speech framework, so
    /// asking for Speech Recognition access would be a prompt the user can't
    /// make sense of — its system-supplied wording says data is sent to Apple,
    /// which is untrue for how we'd use it and completely untrue for Parakeet.
    /// The Apple engine remains available; its permission is requested at the
    /// moment you select it.
    func requestPermissions() {
        if sttEngine == .apple { requestSpeechPermission() }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                if !granted {
                    self?.permissionDenied = true
                    self?.lastError = "Microphone access denied — enable it in System Settings → Privacy & Security → Microphone."
                }
            }
        }
    }

    /// Only ever called when the Apple engine is in play.
    private func requestSpeechPermission() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                self?.permissionDenied = (auth == .denied || auth == .restricted)
                if auth == .authorized { self?.lastError = nil }
            }
        }
    }

    /// True when both permissions are in place and listening can start.
    /// Parakeet transcribes locally without the Speech framework, so it only
    /// needs microphone access.
    var canListen: Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        if sttEngine == .parakeet { return true }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: Push-to-talk (hold space)

    private func installSpaceBarMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }

            // ESC — barge in and shut Athena up. Also catches the window
            // between chunks, when state has briefly dropped to .idle.
            // ESC also aborts a transcription that's dragging on.
            if event.keyCode == 53, event.type == .keyDown, self.transcribing {
                self.cancelTranscription()
                return nil
            }
            if event.keyCode == 53, event.type == .keyDown,
               self.state == .speaking || self.audioPlayer != nil || self.speechPump != nil {
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
        // Already capturing — never restart, that would wipe the transcript.
        guard state != .listening, !finalizing else { return }

        // Permissions must be granted BEFORE touching the audio engine —
        // otherwise the input node reports a 0-channel format and
        // installTap(onBus:) raises an uncatchable exception (a hard crash).
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        // Parakeet never touches the Speech framework, so it only needs the mic.
        let needsSpeechAuth = sttEngine == .apple
        guard micAuth == .authorized, !needsSpeechAuth || speechAuth == .authorized else {
            NSLog("[voice] permissions not granted (speech: %d, mic: %d) — requesting",
                  speechAuth.rawValue, micAuth.rawValue)
            permissionDenied = (micAuth == .denied
                                || (needsSpeechAuth && speechAuth == .denied))
            requestPermissions()
            return
        }

        if sttEngine == .apple {
            guard let recognizer, recognizer.isAvailable else {
                NSLog("[voice] recognizer unavailable")
                return
            }
        } else {
            // Refuse to record audio we have no way to transcribe. Silently
            // capturing while a 600MB model downloads in the background is how
            // this looked broken — the user talks, nothing comes back, and
            // there's no explanation anywhere.
            guard parakeet.isDownloaded || parakeet.status == .ready else {
                NSLog("[voice] parakeet model not downloaded — refusing to record")
                lastError = "Speech model isn't downloaded yet. Open Settings › Voice to download it (600MB, one time) — or switch to the Apple engine there."
                return
            }
        }

        stopSpeaking()

        // Clear all per-session state.
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        teardownEngine()

        resetTranscript(reason: "new session")
        sampleBuffer.reset()
        flowCounter.reset()
        previewSuppressed = false
        didRetryEngineStart = false

        // Single persistent engine (see its declaration). We only reconfigure
        // its tap each session; we never replace the engine.
        _ = audioEngine.inputNode

        // Use the HARDWARE format. A tap MUST be installed at the rate the
        // device actually delivers. `outputFormat(forBus:)` can report a stale
        // 48kHz while the real device (e.g. AirPods at 24kHz) differs, and
        // installing a tap at the wrong rate fails with "Format mismatch /
        // Failed to create tap" and delivers nothing. `inputFormat` is the
        // device's true current format.
        guard let format = currentInputFormat() else {
            NSLog("[voice] invalid input format — aborting")
            state = .idle
            listeningSince = nil
            lastError = "No usable microphone input. Check System Settings → Privacy & Security → Microphone."
            return
        }
        NSLog("[voice] input format (hardware): %.0fHz, %d ch — STT engine: %@",
              format.sampleRate, format.channelCount, sttEngine.rawValue)

        let usingParakeet = sttEngine == .parakeet
        reinstallTap(format: format)

        if !usingParakeet { startSegment() }

        // prepare() then start(). prepare() here (after tap install, before
        // start) is the ordering Apple's own samples use for input capture.
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            NSLog("[voice] audio engine start failed: %@", error.localizedDescription)
            teardownEngine()
            state = .idle
            listeningSince = nil
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        NSLog("[voice] engine started (running=%@)", audioEngine.isRunning ? "yes" : "no")

        listeningSince = .now
        state = .listening

        // Verify audio actually flows. `running=yes` only means the engine's
        // graph started — the HAL device start can still fail asynchronously
        // with error 35 (device busy), in which case the tap never fires.
        // Check the thread-safe counter shortly after start; if nothing has
        // arrived, the device was busy, so stop and try once more after a beat
        // to let it release. This is what actually recovers from error 35.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard self.state == .listening else { return }
            if self.flowCounter.count > 0 {
                NSLog("[voice] audio confirmed flowing (%d buffers)", self.flowCounter.count)
                return
            }
            if !self.didRetryEngineStart {
                self.didRetryEngineStart = true
                NSLog("[voice] no audio yet — device likely busy, restarting engine once")
                self.restartEngineForFlow()
            } else {
                NSLog("[voice] no audio after retry — input is dead")
                self.lastError = "No audio is reaching the microphone. Another app may be using it, or check System Settings → Sound → Input."
            }
        }

        if usingParakeet {
            previewTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runPreviewPass() }
            }
        } else {
            segmentTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.watchdogTick() }
            }
        }
    }

    // MARK: Parakeet preview + final pass

    /// Re-transcribes everything captured so far, purely for on-screen
    /// feedback. Passes never overlap, and a pass that lands after SPACE was
    /// released is discarded so it can't overwrite the real result.
    private func runPreviewPass() {
        guard sttEngine == .parakeet, state == .listening else { return }
        guard !previewRunning, !previewSuppressed else { return }
        guard parakeet.status == .ready else { return }   // still downloading

        // Preview only the most recent window. Re-transcribing the whole
        // recording every 1.5s is quadratic work — on a long dictation it
        // buries the machine and starves the final pass.
        let all = sampleBuffer.snapshot()
        guard all.count > Int(ParakeetAudio.sampleRate * 0.5) else { return }
        let truncated = all.count > ParakeetAudio.chunkLength
        let samples = truncated ? Array(all.suffix(ParakeetAudio.chunkLength)) : all

        previewRunning = true
        let started = Date()
        Task { @MainActor in
            defer { previewRunning = false }
            do {
                let text = try await parakeet.transcribe(samples)
                guard state == .listening, !previewSuppressed else { return }
                if !text.isEmpty {
                    // Leading ellipsis makes it obvious this is a tail view,
                    // not the whole utterance.
                    liveTranscript = truncated ? "… " + text : text
                }
                // Self-tune: if the machine can't keep up, stop previewing
                // rather than fighting the final pass for the ANE.
                let elapsed = Date().timeIntervalSince(started)
                if elapsed > 1.2 {
                    NSLog("[parakeet] preview took %.1fs — disabling live preview", elapsed)
                    previewTimer?.invalidate()
                    previewTimer = nil
                }
            } catch {
                NSLog("[parakeet] preview failed: %@", error.localizedDescription)
            }
        }
    }

    /// SPACE released with Parakeet active: one authoritative pass over the
    /// whole session, then send. No pause handling, no segments, no state to
    /// lose — the buffer holds every sample from press to release.
    private func finishParakeetSession() {
        previewSuppressed = true
        previewTimer?.invalidate()
        previewTimer = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        level = 0
        listeningSince = nil
        teardownEngine()

        let samples = sampleBuffer.snapshot()
        let seconds = Double(samples.count) / ParakeetAudio.sampleRate
        NSLog("[voice] captured %.1fs of audio (%d buffers) — transcribing",
              seconds, flowCounter.count)

        // First run: the model may still be downloading. The audio is safe in
        // the buffer and will transcribe as soon as it's loaded — say so
        // rather than looking hung.
        if parakeet.status != .ready {
            NSLog("[voice] model not ready (%@) — recording queued behind it",
                  parakeet.status.label)
            lastError = "Speech model is still downloading (~600MB, first run only). Your recording will be transcribed as soon as it finishes."
        }

        // Show the preview text while the final pass runs, so the UI doesn't
        // blank out. state stays .listening until we have the answer.
        transcribing = true
        // Release the mic and the UI immediately. The session is over as far
        // as the user is concerned; transcription is background work.
        state = .idle
        finalizing = false

        transcriptionTask = Task { @MainActor in
            defer {
                sampleBuffer.reset()
                resetTranscript(reason: "sent to chat")
                transcribing = false
                transcriptionTask = nil
            }
            var text = ""
            do {
                // Hard bound: generous enough for a long recording on a slow
                // machine, but it can never hang the voice pipeline forever.
                text = try await withTimeout(seconds: max(30, seconds * 2)) { [parakeet] in
                    try await parakeet.transcribe(samples)
                }
            } catch is CancellationError {
                NSLog("[parakeet] transcription cancelled by user")
                return
            } catch is TimeoutError {
                NSLog("[parakeet] transcription timed out after %.0fs of audio", seconds)
                lastError = "Transcription is taking too long — switch to the Apple engine in Settings › Voice if this keeps happening."
            } catch {
                NSLog("[parakeet] final transcription failed: %@", error.localizedDescription)
                lastError = "Transcription failed: \(error.localizedDescription)"
            }
            // Fall back to whatever the preview managed, rather than losing
            // the utterance entirely.
            if text.isEmpty { text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !text.isEmpty else {
                NSLog("[voice] nothing transcribed from %.1fs of audio", seconds)
                return
            }
            NSLog("[voice] final transcript: %d chars", text.count)
            onTranscriptFinal?(text)
        }
    }

    /// When the current segment last produced a hypothesis.
    private var lastResultAt = Date.distantPast
    /// When the current segment started (bounds total lifetime).
    private var segmentStartedAt = Date.now
    /// Quiet time after which a segment with text is committed.
    private let silenceRotateAfter: TimeInterval = 2.0

    private func watchdogTick() {
        guard state == .listening, !finalizing, !rotating else { return }
        let now = Date()
        let hasText = !(liveSegment?.text.isEmpty ?? true)
        let quiet = now.timeIntervalSince(lastResultAt)
        let age = now.timeIntervalSince(segmentStartedAt)

        // Pause detected: bank the words, restart recognition.
        if hasText, quiet > silenceRotateAfter {
            rotateSegment(reason: "silence")
            return
        }
        // An empty segment that's heard nothing for a while gets refreshed
        // too — a dormant recognizer won't reliably wake for new speech, and
        // a fresh one costs nothing. This is what makes arbitrarily long
        // thinking pauses safe.
        if !hasText, quiet > 6.0 {
            rotateSegment(reason: "idle-refresh")
            return
        }
        // Hard ceiling — Apple kills recognition tasks around the minute
        // mark, so hand over before that even mid-speech.
        if age > segmentSeconds {
            rotateSegment(reason: "age")
        }
    }

    /// Removing a tap from a bus that has none throws -10877, so track it.
    private var tapInstalled = false
    /// Buffers delivered by the tap this session — the truthful, thread-safe
    /// proof that audio is flowing (see AudioFlowCounter).
    private let flowCounter = AudioFlowCounter()

    private func removeInputTap() {
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// The microphone's true current format. Prefers the hardware side
    /// (`inputFormat`); falls back to the graph side only if that's unusable.
    /// A tap installed at anything other than the hardware rate fails to
    /// create, which is exactly the 24kHz-device / 48kHz-tap mismatch bug.
    private func currentInputFormat() -> AVAudioFormat? {
        let input = audioEngine.inputNode
        let hw = input.inputFormat(forBus: 0)
        if hw.sampleRate > 0, hw.channelCount > 0 { return hw }
        let out = input.outputFormat(forBus: 0)
        if out.sampleRate > 0, out.channelCount > 0 { return out }
        return nil
    }

    /// Installs the mic tap. Shared by the initial start and the device-busy
    /// retry so both feed audio identically.
    private func reinstallTap(format: AVAudioFormat) {
        removeInputTap()
        let usingParakeet = sttEngine == .parakeet
        var loggedFirstBuffer = false
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Count EVERY buffer synchronously on the audio thread — this is
            // the watchdog's source of truth.
            self.flowCounter.increment()
            if !loggedFirstBuffer {
                loggedFirstBuffer = true
                NSLog("[voice] first buffer: %.0fHz/%dch, %d frames",
                      buffer.format.sampleRate, buffer.format.channelCount, buffer.frameLength)
            }
            if usingParakeet {
                self.sampleBuffer.append(buffer)
            } else {
                self.recognitionRequest?.append(buffer)
            }
            // Level meter is the only thing that needs the main actor, and it
            // tolerates being dropped — so a plain Task is fine here.
            let rms = Self.rmsLevel(buffer)
            Task { @MainActor in self.level = rms }
        }
        tapInstalled = true
    }

    /// Stops the engine and removes the tap, releasing the input device.
    private func teardownEngine() {
        removeInputTap()
        if audioEngine.isRunning { audioEngine.stop() }
    }

    /// Recovery from a device-busy (error 35) start: the HAL reported the
    /// input device busy so the tap never fired. Stop the engine to force the
    /// device to release, wait briefly, then re-arm the SAME tap and restart.
    /// Runs entirely on the existing session's engine — no new engine, so no
    /// second client fighting for the device.
    private func restartEngineForFlow() {
        guard state == .listening else { return }
        // Tear the tap + stop, then let the device settle before re-arming.
        teardownEngine()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard state == .listening else { return }
            // Re-read the format AFTER the device settles — it may have just
            // finished a config change (the reason the first tap failed).
            guard let format = currentInputFormat() else {
                lastError = "No usable microphone input."
                state = .idle
                return
            }
            reinstallTap(format: format)
            audioEngine.prepare()
            do {
                try audioEngine.start()
                NSLog("[voice] engine restarted after device-busy")
            } catch {
                NSLog("[voice] restart failed: %@", error.localizedDescription)
                lastError = "Couldn't start the microphone: \(error.localizedDescription)"
                state = .idle
                return
            }
            // Final verdict a moment later.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard state == .listening else { return }
            if flowCounter.count == 0 {
                NSLog("[voice] still no audio after restart — input is dead")
                lastError = "No audio is reaching the microphone. Another app may be using it, or check System Settings → Sound → Input."
            } else {
                NSLog("[voice] audio flowing after restart (%d buffers)", flowCounter.count)
            }
        }
    }

    /// Starts a fresh recognition request. Transcription runs on the Speech
    /// framework's own queue — never the main thread.
    private func startSegment() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // privacy: local STT
        // Dictation hint makes the recognizer far more tolerant of pauses
        // than the default (which expects short search-style utterances).
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        recognitionRequest = request

        segmentID += 1
        let segment = TranscriptSegment(id: segmentID)
        liveSegment = segment
        segmentStartedAt = .now
        lastResultAt = .now          // grace period before the watchdog acts

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                // Write synchronously on the Speech queue so hypotheses are
                // applied in the order the recognizer produced them.
                segment.update(result.bestTranscription.formattedString,
                               isFinal: result.isFinal)
                let isFinal = result.isFinal
                Task { @MainActor in
                    // A retired segment may still be talking — let it update
                    // its own (unread) box, but never touch the live state.
                    guard self.liveSegment === segment else { return }
                    self.lastResultAt = .now
                    self.refreshTranscript()
                    guard isFinal else { return }
                    if self.finalizing {
                        // SPACE was released — this is the last word.
                        self.resumeFinalResult()
                    } else {
                        // Just a pause mid-thought: commit and keep listening.
                        self.rotateSegment(reason: "pause")
                    }
                }
                return
            }

            if let error {
                let code = (error as NSError).code
                // 203 = "no speech detected", 1110 = "no result" — both are
                // just silence, not failures. Keep the session alive.
                Task { @MainActor in
                    guard self.liveSegment === segment else { return }
                    if self.finalizing { self.resumeFinalResult(); return }
                    guard self.state == .listening else { return }
                    NSLog("[voice] segment %d ended (%d) — rotating", segment.id, code)
                    self.rotateSegment(reason: "recognizer-ended")
                }
            }
        }
    }

    /// Commits what's been recognized so far and swaps in a new request,
    /// keeping the audio tap alive so the user can talk continuously.
    private var rotating = false
    /// Incremented per recognition segment. A cancelled task can still fire
    /// callbacks; without this they overwrite the new segment's text and the
    /// committed transcript appears to reset.
    private var segmentID = 0
    /// True between SPACE release and the send — stops mid-session rotation
    /// from restarting a segment while we're shutting down.
    private var finalizing = false
    /// Resumed when the recognizer delivers its last result after endAudio().
    private var finalResultContinuation: CheckedContinuation<Void, Never>?

    /// Commits the current partial and starts a fresh recognition request,
    /// leaving the audio tap untouched so nothing is missed.
    private func rotateSegment(reason: String = "timer") {
        guard state == .listening, !rotating, !finalizing else { return }
        rotating = true
        defer { rotating = false }

        // Take the text from the box that produced it and seal that box, so
        // nothing the retired task says afterwards can change or erase it.
        if let segment = liveSegment {
            let finished = segment.seal().trimmingCharacters(in: .whitespaces)
            if !finished.isEmpty { committedSegments.append(finished) }
            NSLog("[voice] committed segment %d (%@): +%d chars, %d segments, %d total",
                  segment.id, reason, finished.count,
                  committedSegments.count,
                  committedSegments.joined(separator: " ").count)
        }
        liveSegment = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()      // cancel, not finish — we already have the text
        recognitionTask = nil
        recognitionRequest = nil

        // During a long silence the recognizer can end a segment almost as
        // soon as it starts. Restarting instantly would spin. Back off a beat
        // — the audio tap stays installed, so nothing is missed.
        let sinceLast = Date().timeIntervalSince(lastRotation)
        lastRotation = .now
        if sinceLast < 0.5 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard self.state == .listening, !self.finalizing,
                      self.liveSegment == nil else { return }
                self.startSegment()
                self.refreshTranscript()
            }
        } else {
            startSegment()             // installs a fresh liveSegment
        }
        refreshTranscript()
    }

    /// Timestamp of the last segment rotation, used to throttle restarts.
    private var lastRotation = Date.distantPast

    /// Seconds spent listening in the current session.
    var listeningElapsed: TimeInterval {
        listeningSince.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// SPACE released — the ONLY thing that finalizes and sends.
    ///
    /// Waits for the recognizer's last result (bounded) rather than guessing
    /// with a fixed delay, so trailing words are never clipped.
    func stopListeningAndSend() {
        guard state == .listening, !finalizing else { return }
        finalizing = true

        if sttEngine == .parakeet {
            finishParakeetSession()
            return
        }

        segmentTimer?.invalidate()
        segmentTimer = nil
        level = 0
        listeningSince = nil

        // Stop capturing, then let the recognizer drain what it already has.
        teardownEngine()
        NSLog("[voice] stopping — %d audio buffers captured", flowCounter.count)
        recognitionRequest?.endAudio()

        Task { @MainActor in
            // Only worth waiting if a request is actually in flight — between
            // rotations there's nothing left to drain.
            if recognitionTask != nil { await waitForFinalResult(timeout: 2.0) }

            // Fold the last segment in, then read the whole session.
            if let segment = liveSegment {
                let tail = segment.seal().trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { committedSegments.append(tail) }
                liveSegment = nil
            }
            var final = committedSegments
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Last line of defence: whatever the user was shown is the source
            // of truth. If the teardown path somehow produced less than what
            // was on screen, send what was on screen.
            let onScreen = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if onScreen.count > final.count {
                NSLog("[voice] recovered %d chars from the displayed transcript (had %d)",
                      onScreen.count, final.count)
                final = onScreen
            }

            // Tear down cleanly.
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            resetTranscript(reason: "sent to chat")
            state = .idle
            finalizing = false

            if !final.isEmpty {
                NSLog("[voice] final transcript: %d chars", final.count)
                onTranscriptFinal?(final)
            }
        }
    }

    /// Waits for `isFinal` (or the task ending) after endAudio(), with a cap.
    private func waitForFinalResult(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finalResultContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                resumeFinalResult()   // no-op if already resumed
            }
        }
    }

    private func resumeFinalResult() {
        guard let continuation = finalResultContinuation else { return }
        finalResultContinuation = nil
        continuation.resume()
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

    /// Speaks a finished reply. Ignores the voiceReplies toggle (callers gate
    /// on it). ALL heavy work — markdown stripping, sentence splitting — runs
    /// off the main thread; only the quick tool-noise reject is on-main.
    func speakNow(_ rawText: String) {
        guard !ChatMessage.looksLikeToolNoise(rawText) else {
            NSLog("[voice] refusing to speak tool output (%d chars)", rawText.count)
            return
        }
        stopSpeaking()

        let keepTags = engine.supportsEmotion
        let isSystemEngine = (engine == .system)
        let limit = Self.maxSpeakCharacters

        // Prepare off the main actor: regex cleaning of a long reply can take
        // tens of milliseconds and must never touch the main thread. When it's
        // done, hop back and start playback.
        ttsPrepTask?.cancel()
        ttsPrepTask = Task.detached(priority: .userInitiated) { [weak self] in
            var text = VoiceManager.speakableText(rawText, keepEmotionTags: keepTags)
            guard !text.isEmpty else { return }
            if text.count > limit {
                let cutoff = text.index(text.startIndex, offsetBy: limit)
                let head = String(text[text.startIndex..<cutoff])
                if let lastStop = head.lastIndex(where: { ".!?".contains($0) }) {
                    text = String(head[head.startIndex...lastStop])
                } else {
                    text = head
                }
                text += " That's the short version — the rest is in the chat."
            }
            let sentences = VoiceManager.splitIntoSentences(text)
            let systemText = text
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                if isSystemEngine {
                    self.speakSystem(systemText)   // starts almost instantly
                } else {
                    self.startPump(with: sentences)
                }
            }
        }
    }

    // MARK: Streaming speech
    //
    // Waiting for a whole reply before synthesizing is the main source of lag.
    // Instead we start speaking the first complete sentence while the rest of
    // the reply is still arriving from the gateway.

    // MARK: Serial speech pump
    //
    // Design: TTS is REACTIVE and fully off the main thread. The chat store
    // hands us a finished reply (once the turn completes over the WebSocket);
    // nothing runs per-delta on the network hot path. All cleaning, sentence
    // splitting, and synthesis happen off the main actor, so a slow reply — or
    // a huge one — never blocks or freezes the UI.
    //
    // ONE consumer task ("the pump") owns all playback for a reply. It renders
    // one utterance ahead while the current plays, and awaits each clip's
    // completion before starting the next — so playback is gapless and strictly
    // in order, while still starting on the first sentence rather than waiting
    // for the whole thing to synthesize.

    /// Sentences waiting to be spoken, in order.
    private var sentenceQueue: [String] = []
    /// The single playback consumer for the current reply.
    private var speechPump: Task<Void, Never>?
    /// Off-main text cleaning + sentence splitting for the current reply.
    private var ttsPrepTask: Task<Void, Never>?
    /// One-utterance-ahead synthesis, so the next clip is ready when the
    /// current finishes.
    private var prefetch: Task<Data?, Never>?
    /// Resumed by the player delegate when a clip finishes.
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    /// Set when neural synthesis fails and we hand the rest to the system
    /// voice; stops the pump's exit from cutting that speech off.
    private var handedToSystemVoice = false

    /// Starts speaking a set of pre-split sentences. Only touches main-actor
    /// state (fast); all heavy work already happened off-main in `prepareAndSpeak`.
    private func startPump(with sentences: [String]) {
        guard !sentences.isEmpty else { return }
        interrupted = false
        handedToSystemVoice = false
        sentenceQueue = sentences
        state = .speaking
        startSpeechPump()
    }

    private func startSpeechPump() {
        speechPump?.cancel()
        prefetch?.cancel(); prefetch = nil
        var spokenAnything = false
        speechPump = Task { @MainActor [weak self] in
            guard let self else { return }
            // `Task.isCancelled` — not just `interrupted` — because a new turn
            // resets `interrupted` to false right after cancelling the old
            // pump; without this the retired pump would keep looping.
            while !self.interrupted, !Task.isCancelled {
                guard let data = await self.nextClip(first: !spokenAnything) else { break }
                spokenAnything = true
                guard !self.interrupted, !Task.isCancelled else { break }
                // Kick synthesis of the following utterance while this plays.
                self.schedulePrefetch()
                await self.playAndAwait(data)
            }
            // Don't clobber a system-voice fallback that's mid-sentence, and
            // don't touch state if we were cancelled by a newer turn.
            if !self.interrupted, !Task.isCancelled, !self.handedToSystemVoice {
                self.finishSpeaking()
            }
        }
    }

    /// Returns the next clip's audio, or nil when the reply is fully spoken.
    /// Consumes the prefetched result first so order is preserved. The whole
    /// reply is known when the pump starts, so an empty queue means we're done.
    private func nextClip(first: Bool) async -> Data? {
        guard !interrupted, !Task.isCancelled else { return nil }
        if let p = prefetch {
            prefetch = nil
            return await p.value
        }
        if let utterance = dequeueUtterance(first: first) {
            return await synthesizeChunk(utterance)
        }
        return nil
    }

    private func schedulePrefetch() {
        guard prefetch == nil, !interrupted else { return }
        guard let utterance = dequeueUtterance(first: false) else { return }
        prefetch = Task { [weak self] in await self?.synthesizeChunk(utterance) ?? nil }
    }

    /// Pulls the next utterance to synthesize. The FIRST utterance is a single
    /// sentence so audio starts as fast as possible; later utterances combine
    /// sentences up to a target length so transitions are infrequent and the
    /// speech flows.
    private func dequeueUtterance(first: Bool) -> String? {
        guard !sentenceQueue.isEmpty else { return nil }
        if first { return sentenceQueue.removeFirst() }
        var combined = sentenceQueue.removeFirst()
        while let next = sentenceQueue.first, combined.count + next.count + 1 <= 240 {
            combined += " " + sentenceQueue.removeFirst()
        }
        return combined
    }

    /// Plays one clip and suspends until it finishes (or is stopped). This is
    /// what serializes playback — the pump can't start the next clip until this
    /// resumes, so two clips can never sound at once.
    private func playAndAwait(_ data: Data) async {
        guard data.count > 1024 else {
            NSLog("[voice] skipping empty audio buffer (%d bytes)", data.count)
            return
        }
        guard state == .speaking, !interrupted else { return }
        playbackToken &+= 1
        let token = playbackToken
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.isMeteringEnabled = true
                audioPlayer = player
                playbackContinuation = cont
                let ok = player.play()
                startMeter()
                if !ok {
                    // play() can fail silently while a Bluetooth device is
                    // reconfiguring (HFP↔A2DP). The finish delegate then never
                    // fires, so resume ourselves rather than hang the pump.
                    NSLog("[voice] player.play() returned false — skipping clip")
                    resumePlayback()
                    return
                }
                // Safety net: if the delegate never fires (device reconfig,
                // route loss), advance after the clip's own duration + margin
                // so a single bad clip can't stall the whole reply.
                let timeout = player.duration + 1.5
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard self.playbackToken == token, self.playbackContinuation != nil else { return }
                    NSLog("[voice] playback watchdog fired after %.1fs — advancing", timeout)
                    self.audioPlayer?.stop()
                    self.audioPlayer = nil
                    self.resumePlayback()
                }
            } catch {
                NSLog("[voice] playback failed: %@", error.localizedDescription)
                cont.resume()
            }
        }
    }

    /// Identifies the current clip so a stale watchdog can't resume a newer one.
    private var playbackToken: UInt64 = 0

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.audioPlayer, p.isPlaying else { return }
                p.updateMeters()
                let db = p.averagePower(forChannel: 0)
                self.level = max(0, min(1, (db + 40) / 40))
            }
        }
    }

    /// Resumes the pump after a clip ends or is stopped. Idempotent.
    private func resumePlayback() {
        let cont = playbackContinuation
        playbackContinuation = nil
        cont?.resume()
    }

    /// Surfaced in the HUD when synthesis is waiting on a cold model.
    @Published private(set) var warmingUp = false

    private func synthesizeChunk(_ chunk: String) async -> Data? {
        // A cold neural model can take a while — say so rather than sitting
        // in silence. (Warm engines skip this entirely.)
        switch engine {
        case .kokoro:
            if case .ready = kokoro.status {
                warmingUp = !kokoro.warmVoices.contains(kokoroVoice)
            } else {
                warmingUp = true
            }
        case .cosyVoice:
            if case .ready = cosyVoice.status {} else { warmingUp = true }
        default:
            warmingUp = false
        }
        defer { warmingUp = false }

        let started = Date()
        defer {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 1 {
                NSLog("[voice] chunk synthesis took %.1fs (%d chars)", elapsed, chunk.count)
            }
        }
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
            // Speak the remainder with the system voice rather than going
            // silent. Mark the handoff so the pump's exit won't cut it off.
            let remainder = ([chunk] + sentenceQueue).joined(separator: " ")
            sentenceQueue = []
            prefetch?.cancel(); prefetch = nil
            handedToSystemVoice = true
            speakSystem(remainder)
            return nil
        }
    }

    private func finishSpeaking() {
        prefetch?.cancel()
        prefetch = nil
        ttsPrepTask = nil
        sentenceQueue = []
        speechPump = nil
        meterTimer?.invalidate()
        if state == .speaking { state = .idle; level = 0 }
    }

    /// Strips markdown, emoji and other artifacts that sound wrong when read
    /// aloud. Belt and braces alongside the agent-side voice directive.
    /// - Parameter keepEmotionTags: CosyVoice acts on inline `(happy)` /
    ///   `(whispers)` tags, so they must survive; other engines would read
    ///   them aloud, so they're removed.
    nonisolated static func speakableText(_ raw: String, keepEmotionTags: Bool = false) -> String {
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
    /// Splits text into individual sentences, keeping terminal punctuation.
    /// Fragments too short to be a real sentence are merged into the previous
    /// one so we never synthesize a lone "3." or "Mr.".
    nonisolated static func splitIntoSentences(_ text: String) -> [String] {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        var out: [String] = []
        var current = ""
        for ch in flat {
            current.append(ch)
            if ".!?".contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                // Merge a very short fragment onto the prior sentence.
                if trimmed.count <= 3, !out.isEmpty {
                    out[out.count - 1] += " " + trimmed
                } else if !trimmed.isEmpty {
                    out.append(trimmed)
                }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            if tail.count <= 3, !out.isEmpty { out[out.count - 1] += " " + tail }
            else { out.append(tail) }
        }
        return out
    }

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

    /// Set when the user interrupts. Blocks the pump from queuing more audio
    /// for this turn — otherwise incoming text restarts playback a moment
    /// after you press stop.
    private(set) var interrupted = false

    /// Stops speech immediately — ESC, the Stop button, the orb, or talking.
    func stopSpeaking() {
        interrupted = state == .speaking || speechPump != nil || ttsPrepTask != nil
        ttsPrepTask?.cancel()
        ttsPrepTask = nil
        speechPump?.cancel()
        speechPump = nil
        serverFetchTask?.cancel()
        prefetch?.cancel()
        prefetch = nil
        sentenceQueue = []
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audioPlayer?.stop()
        audioPlayer = nil
        resumePlayback()          // unblock the pump's await so it exits
        meterTimer?.invalidate()
        if state == .speaking { state = .idle; level = 0 }
    }

    /// True whenever audio is playing OR more is queued — so the Stop control
    /// stays visible between clips instead of flickering.
    var isSpeaking: Bool {
        state == .speaking || audioPlayer != nil
            || !sentenceQueue.isEmpty || speechPump != nil || ttsPrepTask != nil
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
            // Hand control back to the pump, which starts the next clip.
            self.resumePlayback()
        }
    }
}

extension VoiceManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.pulseOutputLevel() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Clears a completed pump reference too, so a system-voice fallback
            // doesn't leave `isSpeaking` (and the Stop button) stuck on.
            self.speechPump = nil
            self.handedToSystemVoice = false
            if self.state == .speaking { self.state = .idle; self.level = 0 }
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.state == .speaking { self.state = .idle; self.level = 0 }
        }
    }
}
