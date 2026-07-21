import SwiftUI

/// Setup step for on-device models.
///
/// These are large downloads (hundreds of MB) and they must be an explicit,
/// visible choice. Pulling them lazily the first time someone holds SPACE is
/// indistinguishable from the app being broken: you talk, nothing comes back,
/// and nothing in the UI explains why.
struct ModelSetupStep: View {
    @EnvironmentObject var voice: VoiceManager
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "On-device models")

            Text("Athena transcribes and speaks entirely on your Mac. Download what you need now — nothing is fetched later without asking.")
                .font(Theme.body).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            // ── Speech to text ────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(Theme.amber)
                    Text("Speech to text").font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    statusBadge
                }

                Text("Parakeet — 600 MB, runs on the Neural Engine. Handles long dictation with pauses far better than the built-in macOS recognizer.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                ParakeetStatusRow(stt: voice.parakeet)
            }
            .padding(14)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))

            Text("You can skip this and use the built-in macOS recognizer instead — it needs no download, but is noticeably less accurate on long sentences. Change it any time in Settings › Voice.")
                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Use built-in recognizer instead") {
                    voice.sttEngine = .apple
                    onContinue()
                }
                .buttonStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.textDim)

                Spacer()

                Button(voice.parakeet.isDownloaded ? "Continue" : "Continue without it") {
                    if !voice.parakeet.isDownloaded { voice.sttEngine = .apple }
                    onContinue()
                }
                .buttonStyle(.plain).font(Theme.mono(13, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.black)
            }
        }
        .onAppear { voice.parakeet.refreshDownloadState() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if voice.parakeet.isDownloaded {
            Label("Installed · \(voice.parakeet.downloadedSizeLabel)",
                  systemImage: "checkmark.circle.fill")
                .font(Theme.mono(10)).foregroundStyle(Theme.green)
        } else if voice.parakeet.status.isBusy {
            Label("Downloading…", systemImage: "arrow.down.circle")
                .font(Theme.mono(10)).foregroundStyle(Theme.amber)
        } else {
            Label("Not installed", systemImage: "circle.dashed")
                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
        }
    }
}
