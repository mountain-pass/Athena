import Foundation
import AVFoundation

/// Append-only 16kHz mono Float32 buffer fed from the microphone tap.
///
/// The tap runs on a real-time audio thread, so this is a plain locked class
/// rather than an actor: appends must never suspend or hop actors. Readers
/// take an immutable snapshot, which is what the transcriber runs against.
///
/// This is the whole "pause handling" story now. Silence is just quiet
/// samples in the array — there's no session to expire and nothing to lose,
/// however long the user stops to think.
final class AudioSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Parakeet's required input format.
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: ParakeetAudio.sampleRate,
        channels: 1,
        interleaved: false)!

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    var durationSeconds: Double {
        Double(count) / ParakeetAudio.sampleRate
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        converter = nil
        sourceFormat = nil
    }

    /// Immutable copy for the transcriber to chew on.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Resamples a tap buffer to 16kHz mono and appends it.
    /// Called on the audio thread — no allocation-heavy work beyond the
    /// conversion itself, and never any actor hops.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        // Build (or rebuild) the converter if the input format changed.
        if converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            if converter == nil {
                NSLog("[audio] cannot convert %@ → 16kHz mono", buffer.format)
                lock.unlock()
                return
            }
            NSLog("[audio] resampling %.0fHz/%dch → 16000Hz/1ch",
                  buffer.format.sampleRate, buffer.format.channelCount)
        }
        guard let converter else { lock.unlock(); return }
        lock.unlock()

        // Output capacity must cover the sample-rate ratio, with headroom.
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat,
                                         frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            // Hand over the input exactly once; anything more and the
            // converter will keep asking and stall.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            NSLog("[audio] conversion failed: %@", error.localizedDescription)
            return
        }
        guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        let converted = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
    }
}
