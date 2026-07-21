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
            VoiceSettingsTab(voice: voice, chat: app.chat)
                .tabItem { Label("Voice", systemImage: "waveform") }
            AgentSettingsTab()
                .tabItem { Label("Agent", systemImage: "brain") }
            WidgetSettingsTab(stocks: app.stocks, carousel: app.carousel, news: app.news)
                .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
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
    @ObservedObject var chat: ChatStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Speak replies to voice messages", isOn: $voice.voiceReplies)
                    .font(Theme.body)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Ask the agent to reply conversationally on voice turns",
                           isOn: Binding(get: { chat.useVoiceDirective },
                                         set: { chat.useVoiceDirective = $0 }))
                        .font(Theme.body)
                    Text("Sends a short hint with spoken messages so replies come back as plain speakable sentences instead of markdown with bullets and emoji. Athena also strips any leftover formatting before reading aloud.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                    case .cosyVoice: cosySection
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
                        Button {
                            Task { await voice.kokoro.prepare() }
                        } label: {
                            Label("RETRY", systemImage: "arrow.clockwise")
                                .font(Theme.label).kerning(1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.amber).clipShape(Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
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

    // CosyVoice 3 — emotional, on-device

    private var cosySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            CosyStatusRow(cosy: voice.cosyVoice, variant: voice.cosyVariant)

            SettingsRow("Model size") {
                Picker("", selection: $voice.cosyVariant) {
                    ForEach(CosyVoiceEngine.Variant.allCases) { v in Text(v.rawValue).tag(v) }
                }
                .labelsHidden()
            }

            CosyVoicePicker(voice: voice)

            SettingsRow("Default style (optional)") {
                TextField("e.g. You are a warm, concise assistant.",
                          text: $voice.cosyInstruction)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(11))
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Emotion tags")
                Text("CosyVoice acts on inline tags — the agent can write “(happy) Good news!” or “(whispers) between you and me…” and the delivery changes. Unknown tags work as freeform direction, e.g. “(Speak like a pirate)”.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                FlowTags(tags: CosyVoiceEngine.emotions)
                Button("Preview with emotion") {
                    voice.speakNow("(excited) The markets just moved. (calm) But nothing needs your attention right now.")
                }
                .font(Theme.mono(11))
            }

            helpText("CosyVoice 3 (0.5B) runs on-device via MLX. Bigger and slower to start than Kokoro, but far more expressive and capable of voice cloning. Weights cache in ~/Library/Caches/qwen3-speech. Requires macOS 15+ and Apple Silicon.")
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

// MARK: - Agent provisioning

private struct AgentSettingsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var gateway: GatewayClient
    @State private var showManual = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Athena is only the interface — the agent does the work. Sync writes an operating manual into the agent's workspace (AGENTS.md + HEARTBEAT.md), seeds the shared todo files, and schedules its jobs — so it knows how to archive news, run delegated tasks, when to summarize from memory, and how to answer voice turns.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button(app.provisioner.running ? "Syncing…" : "Sync agent configuration") {
                        Task {
                            await app.provisioner.provision(news: app.news, todos: app.todos)
                            app.chat.agentProvisioned = true
                        }
                    }
                    .disabled(app.provisioner.running || !gateway.state.isConnected)

                    Button("Preview manual") { showManual = true }

                    switch app.provisioner.handshake {
                    case .alreadyProvisioned(let v):
                        Label("contract v\(v) verified", systemImage: "checkmark.seal.fill")
                            .font(Theme.mono(10)).foregroundStyle(Theme.green)
                    case .provisioned(let reason):
                        Label("provisioned (\(reason))", systemImage: "checkmark.seal.fill")
                            .font(Theme.mono(10)).foregroundStyle(Theme.green)
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle")
                            .font(Theme.mono(10)).foregroundStyle(Theme.red)
                    case nil:
                        EmptyView()
                    }
                }

                if !app.provisioner.log.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(app.provisioner.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(Theme.mono(10))
                                .foregroundStyle(line.hasPrefix("✗") || line.contains("✗")
                                                 ? Theme.red : Theme.textDim)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text("Re-run this after changing news topics, sources, or the brief time — the manual embeds them. Your own edits to AGENTS.md are preserved; only the fenced ATHENA section is replaced.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .padding(24)
        }
        .sheet(isPresented: $showManual) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Agent operating manual").font(Theme.title).foregroundStyle(Theme.text)
                    Spacer()
                    Button("Close") { showManual = false }
                }
                ScrollView {
                    Text(app.provisioner.operatingManual(news: app.news))
                        .font(Theme.mono(10))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(width: 640, height: 560)
            .background(Theme.bg)
        }
    }
}

/// CosyVoice has no built-in voice catalogue — you pick a voice by giving it
/// a reference clip to clone. Two routes: borrow a Kokoro voice, or import
/// your own recording.
struct CosyVoicePicker: View {
    @ObservedObject var voice: VoiceManager
    @State private var showImporter = false
    @State private var showRecorder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Voice (cloned from a reference clip)")

            HStack(spacing: 8) {
                Image(systemName: voice.cosyVoice.voiceSamplePath.isEmpty
                      ? "person.wave.2" : "person.wave.2.fill")
                    .foregroundStyle(voice.cosyVoice.voiceSamplePath.isEmpty
                                     ? Theme.textFaint : Theme.green)
                Text(voice.cosyVoice.voiceSamplePath.isEmpty
                     ? "Default CosyVoice voice"
                     : (voice.cosyVoice.voiceSampleLabel.isEmpty
                        ? (voice.cosyVoice.voiceSampleURL?.lastPathComponent ?? "Custom clip")
                        : voice.cosyVoice.voiceSampleLabel))
                    .font(Theme.mono(11)).foregroundStyle(Theme.text)
                if voice.cosyVoice.buildingReference {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Spacer()
                if !voice.cosyVoice.voiceSamplePath.isEmpty {
                    Button("Reset") { voice.cosyVoice.clearReference() }
                        .font(Theme.mono(10)).foregroundStyle(Theme.red)
                        .buttonStyle(.plain)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Borrow a Kokoro voice as the reference.
            Text("Use a Kokoro voice as the reference")
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(KokoroEngine.voices, id: \.id) { candidate in
                        Button {
                            Task {
                                await voice.cosyVoice.buildReference(
                                    fromKokoroVoice: candidate.id,
                                    label: candidate.label,
                                    using: voice.kokoro)
                            }
                        } label: {
                            Text(candidate.label.components(separatedBy: " (").first
                                 ?? candidate.id)
                                .font(Theme.mono(10))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(voice.cosyVoice.voiceSampleLabel == candidate.label
                                            ? Theme.green.opacity(0.18) : Theme.panelAlt)
                                .clipShape(Capsule())
                                .foregroundStyle(voice.cosyVoice.voiceSampleLabel == candidate.label
                                                 ? Theme.green : Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .disabled(voice.cosyVoice.buildingReference)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    showRecorder = true
                } label: {
                    Label("RECORD MY VOICE", systemImage: "mic.fill")
                        .font(Theme.label).kerning(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.amber).clipShape(Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                Button("Import a clip…") { showImporter = true }
                    .font(Theme.mono(10))
                Button("Reveal clips") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: CosyVoiceEngine.referenceDirectory.path)
                }
                .font(Theme.mono(10))
            }

            Text("CosyVoice ships one default voice — everything else is zero-shot cloning from a short reference clip (5–15 seconds, clean audio, one speaker). Borrowing a Kokoro voice requires the Kokoro model to be downloaded; it synthesizes a sample, then CosyVoice clones it.")
                .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio, .wav, .mp3],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            // Copy into our own directory so the path stays valid.
            try? FileManager.default.createDirectory(
                at: CosyVoiceEngine.referenceDirectory, withIntermediateDirectories: true)
            let destination = CosyVoiceEngine.referenceDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: url, to: destination)
            voice.cosyVoice.voiceSamplePath = destination.path
            voice.cosyVoice.voiceSampleLabel = url.deletingPathExtension().lastPathComponent
        }
        .sheet(isPresented: $showRecorder) {
            RecordVoiceSampleSheet(voice: voice)
        }
    }
}

/// Status + load/unload for the embedded CosyVoice model.
struct CosyStatusRow: View {
    @ObservedObject var cosy: CosyVoiceEngine
    let variant: CosyVoiceEngine.Variant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch cosy.status {
            case .ready:
                Label(cosy.status.label, systemImage: "checkmark.circle.fill")
                    .font(Theme.mono(11)).foregroundStyle(Theme.green)

            case .downloading(let fraction, _):
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 340)
                        .tint(Theme.amber)
                    HStack(spacing: 8) {
                        Text(cosy.status.label)
                            .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                        Text(variant.rawValue.components(separatedBy: " (").last?
                            .replacingOccurrences(of: ")", with: "") ?? "")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    }
                }

            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(cosy.status.label)
                        .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                }

            case .unavailable(let why):
                VStack(alignment: .leading, spacing: 6) {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.mono(11)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await cosy.retry(variant: variant) }
                    } label: {
                        Label("RETRY", systemImage: "arrow.clockwise")
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.amber).clipShape(Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }

            case .notLoaded:
                Text(cosy.status.label)
                    .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
            }

            HStack(spacing: 12) {
                Button(cosy.isDownloaded ? "Load model" : "Download & load model") {
                    Task { await cosy.prepare(variant: variant) }
                }
                .disabled(cosy.status.isBusy)

                if cosy.isDownloaded {
                    Button("Unload") { cosy.unload() }.disabled(cosy.status.isBusy)
                    Button("Reveal cache") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: CosyVoiceEngine.cacheDirectory.path)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cosy.status)
    }
}

/// Horizontal tag strip for the emotion list.
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text("(\(tag))")
                        .font(Theme.mono(10))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.panelAlt).clipShape(Capsule())
                        .foregroundStyle(Theme.amber)
                }
            }
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
