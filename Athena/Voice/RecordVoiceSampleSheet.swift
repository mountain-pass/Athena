import SwiftUI

/// Record a reference clip in-app, then use it as the CosyVoice clone source.
struct RecordVoiceSampleSheet: View {
    @ObservedObject var voice: VoiceManager
    @StateObject private var recorder = VoiceSampleRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var label = "My voice"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Voice cloning", color: Theme.amber)
                    Text("Record a sample").font(Theme.title).foregroundStyle(Theme.text)
                }
                Spacer()
                Button { recorder.reset(); dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }

            // Script
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Read this aloud, naturally")
                Text(VoiceSampleRecorder.script)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Meter + timer
            VStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(0..<28, id: \.self) { bar in
                        let threshold = Float(bar) / 28
                        Capsule()
                            .fill(recorder.level > threshold
                                  ? (threshold > 0.8 ? Theme.red : Theme.amber)
                                  : Theme.border)
                            .frame(width: 3,
                                   height: 6 + CGFloat(max(0, recorder.level - threshold)) * 40)
                    }
                }
                .frame(height: 30)
                .animation(.linear(duration: 0.05), value: recorder.level)

                // Progress toward a good-length sample
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border).frame(height: 4)
                        Capsule()
                            .fill(recorder.isUsable ? Theme.green : Theme.amber)
                            .frame(width: geo.size.width
                                   * min(1, recorder.duration / recorder.targetSeconds),
                                   height: 4)
                    }
                }
                .frame(height: 4)

                HStack {
                    Text(String(format: "%.1fs", recorder.duration))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(recorder.isUsable
                         ? "Good length ✓"
                         : "aim for ~\(Int(recorder.targetSeconds)) seconds")
                        .font(Theme.mono(10))
                        .foregroundStyle(recorder.isUsable ? Theme.green : Theme.textFaint)
                }
            }

            if case .failed(let why) = recorder.phase {
                Text(why).font(Theme.mono(11)).foregroundStyle(Theme.red)
            }

            // Controls
            HStack(spacing: 12) {
                switch recorder.phase {
                case .recording:
                    Button { recorder.stop() } label: {
                        Label("STOP", systemImage: "stop.fill")
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Theme.red).clipShape(Capsule())
                            .foregroundStyle(.white)
                    }.buttonStyle(.plain)

                default:
                    Button { recorder.start() } label: {
                        Label(recorder.recordedURL == nil ? "RECORD" : "RE-RECORD",
                              systemImage: "mic.fill")
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Theme.amber).clipShape(Capsule())
                            .foregroundStyle(.black)
                    }.buttonStyle(.plain)
                }

                if recorder.recordedURL != nil, recorder.phase != .recording {
                    Button {
                        recorder.phase == .playing ? recorder.stopPlayback() : recorder.playback()
                    } label: {
                        Label(recorder.phase == .playing ? "Stop" : "Play back",
                              systemImage: recorder.phase == .playing ? "stop.circle" : "play.circle")
                            .font(Theme.mono(11)).foregroundStyle(Theme.text)
                    }.buttonStyle(.plain)
                }

                Spacer()

                if recorder.isUsable {
                    TextField("Name", text: $label)
                        .textFieldStyle(.plain).font(Theme.mono(11))
                        .padding(6).frame(width: 120)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        if let url = recorder.recordedURL {
                            voice.cosyVoice.voiceSamplePath = url.path
                            voice.cosyVoice.voiceSampleLabel = label
                        }
                        dismiss()
                    } label: {
                        Text("USE THIS VOICE").font(Theme.label).kerning(1)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.green).clipShape(Capsule())
                            .foregroundStyle(.black)
                    }.buttonStyle(.plain)
                }
            }

            Divider().overlay(Theme.border)

            Text("Tips: quiet room, normal speaking pace, one voice only. Everything stays on this Mac — the clip is saved locally and never uploaded. Only clone a voice you have the right to use: your own, or one you have permission for.")
                .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.bg)
        .onDisappear { recorder.stopPlayback() }
    }
}
