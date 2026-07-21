import Foundation
import AVFoundation

/// Records a short reference clip for voice cloning.
///
/// Writes 24kHz mono 16-bit WAV — the format CosyVoice's speaker encoder
/// expects. Recording happens on AVAudioRecorder's own thread; only the
/// level/duration updates touch the main actor.
@MainActor
final class VoiceSampleRecorder: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle, recording, recorded, playing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var recordedURL: URL?

    /// Enough audio for a good clone without being a chore to read.
    let targetSeconds: TimeInterval = 14
    let minimumSeconds: TimeInterval = 5

    /// Suggested script — phonetically varied, natural cadence.
    static let script = """
        Hello, this is my voice. I'm recording a short sample so Athena can \
        speak with it. The quick brown fox jumps over the lazy dog. \
        I usually check the news in the morning, then get on with work. \
        If anything urgent comes up, just tell me straight away.
        """

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?

    var isUsable: Bool { duration >= minimumSeconds && recordedURL != nil }

    // MARK: Recording

    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.start() }
                    else { self?.phase = .failed("Microphone access denied") }
                }
            }
            return
        }

        stopPlayback()
        let directory = CosyVoiceEngine.referenceDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("my-voice-\(Int(Date().timeIntervalSince1970)).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record() else {
                phase = .failed("Could not start recording")
                return
            }
            self.recorder = recorder
            recordedURL = url
            duration = 0
            phase = .recording

            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 45) / 45))
        duration = recorder.currentTime
        // Auto-stop once we have plenty.
        if duration >= targetSeconds + 6 { stop() }
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        level = 0
        phase = isUsable ? .recorded : .failed("Too short — record at least \(Int(minimumSeconds)) seconds")
    }

    // MARK: Preview

    func playback() {
        guard let recordedURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: recordedURL)
            player.delegate = self
            player.play()
            self.player = player
            phase = .playing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        if phase == .playing { phase = .recorded }
    }

    func discard() {
        stopPlayback()
        if let recordedURL { try? FileManager.default.removeItem(at: recordedURL) }
        recordedURL = nil
        duration = 0
        phase = .idle
    }

    func reset() {
        stopPlayback()
        recorder?.stop()
        recorder = nil
        duration = 0
        level = 0
        phase = .idle
    }
}

extension VoiceSampleRecorder: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder,
                                                     successfully flag: Bool) {
        Task { @MainActor in
            if !flag { self.phase = .failed("Recording failed") }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if self.phase == .playing { self.phase = .recorded }
        }
    }
}
