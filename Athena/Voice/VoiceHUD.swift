import SwiftUI

/// Floating listening/speaking indicator shown over any tab.
/// The orb panel only exists on the Chat tab, so without this, holding SPACE
/// on News or Jobs gave no feedback at all.
struct VoiceHUD: View {
    @EnvironmentObject var voice: VoiceManager

    /// "Listening…" while the mic is open; once SPACE is released the mic is
    /// already closed, so claiming to listen would be a lie.
    private var headline: String {
        if voice.transcribing {
            if !voice.liveTranscript.isEmpty { return voice.liveTranscript }
            // Distinguish "working on it" from "still fetching the model" —
            // otherwise a multi-minute first-run download looks like a hang.
            if voice.sttEngine == .parakeet, voice.parakeet.status != .ready {
                return "Downloading speech model…"
            }
            return "Transcribing…"
        }
        return voice.liveTranscript.isEmpty ? "Listening…" : voice.liveTranscript
    }

    var body: some View {
        VStack {
            Spacer()
            // Also shown while transcribing: the mic is closed by then, but
            // this is what carries the progress spinner and the cancel button.
            if voice.state == .listening || voice.transcribing {
                listeningCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if voice.warmingUp {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Warming up the voice model — first reply takes a moment")
                        .font(Theme.mono(11)).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.panel.opacity(0.97))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.amber.opacity(0.5), lineWidth: 1))
                .transition(.opacity)
            } else if voice.isSpeaking {
                speakingCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let error = voice.lastError {
                errorCard(error)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 28)
        .animation(.spring(duration: 0.3), value: voice.state)
        .animation(.spring(duration: 0.3), value: voice.transcribing)
        .allowsHitTesting(voice.state != .listening)
    }

    private var listeningCard: some View {
        HStack(spacing: 12) {
            // Live level meter
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let threshold = Float(i) * 0.18
                    Capsule()
                        .fill(voice.level > threshold ? Theme.amber : Theme.amber.opacity(0.2))
                        .frame(width: 3,
                               height: 6 + CGFloat(min(1, max(0, voice.level - threshold)) * 18))
                }
            }
            .frame(height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .frame(maxWidth: 460, alignment: .leading)
                if voice.transcribing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("ESC to cancel")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                        Button("CANCEL") { voice.cancelTranscription() }
                            .buttonStyle(.plain)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.red)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(timeLabel(voice.listeningElapsed)) · pause as long as you like · release SPACE to send")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.panel.opacity(0.97))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.amber.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
    }

    private var speakingCard: some View {
        Button { voice.stopSpeaking() } label: {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.blue)
                Text("Speaking — click or press ESC to stop")
                    .font(Theme.mono(11)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.panel.opacity(0.97))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.blue.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
            Text(message).font(Theme.mono(11)).foregroundStyle(Theme.text)
                .frame(maxWidth: 420, alignment: .leading)
            Button { voice.lastError = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textDim)
                    // The glyph alone was a ~9pt target. Padding plus an
                    // explicit contentShape gives a comfortable hit area
                    // without making the icon look oversized.
                    .padding(6)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.panel.opacity(0.97))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.red.opacity(0.5), lineWidth: 1))
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
