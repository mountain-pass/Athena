import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var gateway: GatewayClient
    @EnvironmentObject var voice: VoiceManager

    var body: some View {
        TabView {
            ConnectionSettingsTab()
                .tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
            VoiceSettingsTab(voice: voice)
                .tabItem { Label("Voice", systemImage: "waveform") }
        }
        .frame(width: 620, height: 560)
        .background(Theme.bg)
    }
}

// MARK: - Connection

private struct ConnectionSettingsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var gateway: GatewayClient
    @State private var settings = ConnectionSettings.load()
    @State private var status: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsRow("Gateway URL") {
                    TextField("wss://host or ws://host:18789", text: $settings.urlString)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                }
                SettingsRow("Gateway token") {
                    SecureField("token", text: $settings.token)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                }

                HStack(spacing: 12) {
                    Button("Reconnect") {
                        gateway.connect(settings)
                        status = "Connecting…"
                    }
                    if case .connected(let v) = gateway.state {
                        Text("✓ Connected (v\(v))").font(Theme.mono(11)).foregroundStyle(Theme.green)
                    } else if let err = gateway.lastError {
                        Text(err).font(Theme.mono(11)).foregroundStyle(Theme.red)
                            .lineLimit(2)
                    } else if let status {
                        Text(status).font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                }

                if let pairing = gateway.pairingInstructions {
                    Text(pairing)
                        .font(Theme.mono(10)).foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.amber.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Divider().overlay(Theme.border)

                Button("Re-run first-time setup", role: .destructive) { app.resetSetup() }
                Spacer()
            }
            .padding(24)
        }
    }
}

// MARK: - Voice

private struct VoiceSettingsTab: View {
    @ObservedObject var voice: VoiceManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Speak replies to voice messages", isOn: $voice.voiceReplies)
                    .font(Theme.body)

                SettingsRow("TTS engine") {
                    Picker("", selection: $voice.engine) {
                        ForEach(VoiceManager.TTSEngine.allCases) { e in Text(e.rawValue).tag(e) }
                    }
                    .labelsHidden()
                }

                Group {
                    switch voice.engine {
                    case .system: systemSection
                    case .kokoro: kokoroSection
                    case .server: serverSection
                    }
                }

                Divider().overlay(Theme.border)

                Button("Preview voice") {
                    voice.speakNow("Hello Sam, this is Athena. This is how I will sound.")
                }

                Text("Hold SPACE (with an empty message box) to talk. Typed messages get typed replies.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                if voice.permissionDenied {
                    Text("⚠ Microphone or speech recognition permission denied — enable in System Settings → Privacy & Security.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Request microphone & speech permissions") { voice.requestPermissions() }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // System voices

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("Voice") {
                Picker("", selection: $voice.systemVoiceID) {
                    Text("Default").tag("")
                    ForEach(voice.availableSystemVoices, id: \.identifier) { v in
                        Text("\(v.name) — \(qualityLabel(v.quality))").tag(v.identifier)
                    }
                }
                .labelsHidden()
            }
            SettingsRow("Speed") {
                Slider(value: $voice.speechRate, in: 0.35...0.65)
            }
            helpText("Better voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices. Download a “Premium” or “Enhanced” voice (Zoe, Ava, Serena) and it appears here.")
        }
    }

    // Embedded Kokoro

    private var kokoroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("Voice") {
                Picker("", selection: $voice.kokoroVoice) {
                    ForEach(KokoroEngine.voices, id: \.id) { v in Text(v.label).tag(v.id) }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                switch voice.kokoro.status {
                case .ready:
                    Label(voice.kokoro.status.label, systemImage: "checkmark.circle.fill")
                        .font(Theme.mono(11)).foregroundStyle(Theme.green)
                case .downloading(let p):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: p).frame(maxWidth: 320)
                        HStack {
                            Text(voice.kokoro.status.label)
                                .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                            Button("Cancel") { voice.kokoro.cancelDownload() }
                                .font(Theme.mono(10)).foregroundStyle(Theme.red)
                        }
                    }
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(voice.kokoro.status.label)
                            .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    }
                case .unavailable(let why):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(why, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.mono(11)).foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Downloads resume automatically and retry up to 5 times. If it keeps failing, fetch the two files manually — see README → Kokoro manual install.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .notLoaded:
                    Text(voice.kokoro.status.label)
                        .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                }

                HStack(spacing: 12) {
                    Button(voice.kokoro.isDownloaded ? "Load model" : "Download model (~330MB)") {
                        Task { await voice.kokoro.prepare() }
                    }
                    if voice.kokoro.isDownloaded {
                        Button("Delete model") { voice.kokoro.deleteAssets() }
                            .foregroundStyle(Theme.red)
                    }
                    Button("Reveal folder") {
                        NSWorkspace.shared.selectFile(nil,
                            inFileViewerRootedAtPath: KokoroEngine.assetDirectory.path)
                    }
                }
            }

            helpText("Kokoro-82M runs fully on-device on Apple Silicon (M1+) — no server, no Docker, works offline. Weights download once from HuggingFace; voices fetch on demand. Falls back to the system voice if anything fails.")
        }
    }

    // Remote server

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("Server URL") {
                TextField("http://localhost:8880", text: $voice.serverURL)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(11))
            }
            SettingsRow("Voice ID") {
                TextField("af_heart", text: $voice.serverVoice)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(11))
            }
            helpText("Any OpenAI-compatible /v1/audio/speech endpoint — kokoro-fastapi or a CosyVoice server (which adds voice cloning and emotional control). Running it on your Mac Mini: use http://<mini-tailscale-name>:8880. Falls back to the system voice if unreachable.")
        }
    }

    private func helpText(_ s: String) -> some View {
        Text(s)
            .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }
}

/// Label above a control — avoids the cramped Form label column that
/// squashes text when the window is narrow.
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(Theme.mono(9, weight: .medium)).kerning(1)
                .foregroundStyle(Theme.textFaint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
