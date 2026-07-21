import Foundation
import AVFoundation
import Speech
import AppKit

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
               self.state == .speaking || self.streamActive || self.audioPlayer != nil {
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
        // Tear down any previous session. NOTE: do NOT call audioEngine.reset()
        // here. On macOS 15 that drops the engine's HAL input proxy, and the
        // next inputNode access rebuilds it with the *default* (not hardware)
        // format — which is where the -10877 kAudioUnitErr_InvalidElement
        // storm and the silent "no audio ever reached the recognizer" failure
        // came from. Stopping and removing the tap is sufficient.
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()

        resetTranscript(reason: "new session")
        sampleBuffer.reset()
        previewSuppressed = false

        // One long-lived audio tap. With Apple, recognition requests rotate
        // underneath it; with Parakeet it just fills a sample buffer.
        let input = audioEngine.inputNode

        // prepare() FIRST, then read the format. The input node only settles
        // onto the real hardware format once the engine has been prepared;
        // querying before that can return a stale or half-built description.
        // (This is why we saw 24000Hz — Kokoro's synthesis rate — for a mic
        // that actually runs at 48k. Declaring half the true sample rate made
        // the tap hand the recognizer mangled audio, so 14s of speech came
        // back as four words.)
        audioEngine.prepare()

        // outputFormat, not inputFormat: for AVAudioEngine's input node the
        // *output* side of bus 0 is what the tap receives. This is Apple's
        // documented pattern; inputFormat describes the hardware side and does
        // not necessarily match what installTap will deliver.
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
        NSLog("[voice] input format: %.0fHz, %d ch — STT engine: %@",
              format.sampleRate, format.channelCount, sttEngine.rawValue)

        listeningSince = .now
        state = .listening
        tapBufferCount = 0

        // Captured by the (single) audio thread, so a plain local is fine and
        // avoids touching main-actor state from a real-time callback.
        var verifiedTapFormat = false
        let usingParakeet = sttEngine == .parakeet

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Verify once that what we're handed matches what we declared. A
            // mismatch means the recognizer is being fed audio at the wrong
            // rate, which degrades it to near-noise — worth screaming about.
            if !verifiedTapFormat {
                verifiedTapFormat = true
                let actual = buffer.format
                if abs(actual.sampleRate - format.sampleRate) > 1
                    || actual.channelCount != format.channelCount {
                    NSLog("[voice] TAP FORMAT MISMATCH — declared %.0fHz/%dch, got %.0fHz/%dch",
                          format.sampleRate, format.channelCount,
                          actual.sampleRate, actual.channelCount)
                } else {
                    NSLog("[voice] tap format confirmed: %.0fHz/%dch, %d frames/buffer",
                          actual.sampleRate, actual.channelCount, buffer.frameLength)
                }
            }
            if usingParakeet {
                // Batch model: just bank the audio. Resampling to 16kHz mono
                // happens inside, off the main actor.
                self.sampleBuffer.append(buffer)
            } else {
                // Feed whichever request is current right now.
                self.recognitionRequest?.append(buffer)
            }
            let rms = Self.rmsLevel(buffer)
            Task { @MainActor in
                self.tapBufferCount += 1
                self.level = rms
            }
        }
        tapInstalled = true

        if !usingParakeet { startSegment() }

        do {
            try audioEngine.start()
        } catch {
            NSLog("[voice] audio engine start failed: %@", error.localizedDescription)
            removeInputTap()
            state = .idle
            listeningSince = nil
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        // Watchdog: if the tap never fires, the mic is dead and the user would
        // otherwise talk into a void and get an empty message. Say so.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self.state == .listening, self.tapBufferCount == 0 else { return }
            NSLog("[voice] no audio buffers after 1.5s — input is dead")
            self.lastError = "No audio is reaching the microphone. Check System Settings → Sound → Input, then try again."
        }

        if usingParakeet {
            // Rolling preview so there's text on screen while you speak. The
            // authoritative transcription happens once, on release.
            previewTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runPreviewPass() }
            }
        } else {
            // Apple only. Silence watchdog: we do NOT trust the recognizer to
            // tell us about pauses — on-device dictation often goes dormant
            // after a few seconds of silence, emitting no final, no error, and
            // no further callbacks. So we track when the last hypothesis
            // arrived and rotate segments ourselves.
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
        audioEngine.stop()
        removeInputTap()

        let samples = sampleBuffer.snapshot()
        let seconds = Double(samples.count) / ParakeetAudio.sampleRate
        NSLog("[voice] captured %.1fs of audio (%d buffers) — transcribing",
              seconds, tapBufferCount)

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
    /// Buffers delivered by the tap this session — proves audio is flowing.
    private var tapBufferCount = 0

    private func removeInputTap() {
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
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
        audioEngine.stop()
        removeInputTap()
        NSLog("[voice] stopping — %d audio buffers captured", tapBufferCount)
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
        interrupted = false          // a new turn clears the interrupt
        streamConsumedCount = 0
        streamActive = true
        state = .speaking          // claim the state so nothing else interrupts
    }

    /// Feed the reply-so-far; any newly completed sentences are queued.
    func appendStreamingSpeech(fullTextSoFar: String) {
        guard !interrupted, streamActive, voiceReplies else { return }
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
        guard !interrupted else { return }   // user stopped this turn
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
        // A failed synthesis returns an empty/near-empty WAV; AVAudioPlayer
        // logs "mDataByteSize (0) should be non-zero" and misbehaves.
        guard data.count > 1024 else {
            NSLog("[voice] skipping empty audio buffer (%d bytes)", data.count)
            finishSpeaking()
            return
        }
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

    /// Set when the user interrupts. Blocks the streaming pipeline from
    /// queuing more chunks for this turn — otherwise incoming text restarts
    /// playback a moment after you press stop.
    private(set) var interrupted = false

    /// Stops speech immediately — ESC, the Stop button, the orb, or talking.
    func stopSpeaking() {
        interrupted = streamActive || state == .speaking
        streamActive = false
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

    /// True whenever audio is playing OR more is queued — so the Stop control
    /// stays visible between chunks instead of flickering.
    var isSpeaking: Bool {
        state == .speaking || streamActive || audioPlayer != nil || !chunkQueue.isEmpty
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
