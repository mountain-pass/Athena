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
            VStack(alignment: .leading, spacing: 14) {

                // ── 1. When Athena speaks ─────────────────────
                SettingsCard(title: "When Athena speaks", icon: "speaker.wave.2.fill") {
                    Toggle("Speak replies to voice messages", isOn: $voice.voiceReplies)
                        .font(Theme.body)
                    Text("Typed messages always get typed replies.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)

                    Divider().overlay(Theme.border).padding(.vertical, 2)

                    Toggle("Ask the agent to reply conversationally",
                           isOn: Binding(get: { chat.useVoiceDirective },
                                         set: { chat.useVoiceDirective = $0 }))
                        .font(Theme.body)
                    Text("Spoken turns come back as plain sentences instead of markdown and bullets.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ── 1b. Speech to text ────────────────────────
                SettingsCard(title: "When you speak", icon: "mic.fill") {
                    Picker("", selection: $voice.sttEngine) {
                        ForEach(VoiceManager.STTEngine.allCases) { e in Text(e.rawValue).tag(e) }
                    }
                    .labelsHidden()

                    switch voice.sttEngine {
                    case .parakeet:
                        ParakeetStatusRow(stt: voice.parakeet)
                        Text("Transcribes the whole recording when you release SPACE, so you can pause as long as you like while thinking. Runs on the Neural Engine — nothing leaves your Mac.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    case .apple:
                        Text("Built into macOS. No download, but tuned for short commands — it misrecognises long-form speech and can stop transcribing after a pause.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // ── 2. Engine ─────────────────────────────────
                SettingsCard(title: "Engine", icon: "cpu") {
                    Picker("", selection: $voice.engine) {
                        ForEach(VoiceManager.TTSEngine.allCases) { e in Text(e.rawValue).tag(e) }
                    }
                    .labelsHidden()

                    switch voice.engine {
                    case .system:
                        Text("Built into macOS. Instant, no download.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    case .kokoro:
                        KokoroStatusRow(kokoro: voice.kokoro)
                        Text("82M model, ~330 MB. Fast and natural; 12 preset voices.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    case .cosyVoice:
                        CosyStatusRow(cosy: voice.cosyVoice, variant: voice.cosyVariant)
                        HStack {
                            Text("Model size").font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                            Picker("", selection: $voice.cosyVariant) {
                                ForEach(CosyVoiceEngine.Variant.allCases) { v in
                                    Text(v.rawValue).tag(v)
                                }
                            }
                            .labelsHidden().frame(maxWidth: 260)
                        }
                        Text("0.5B model via MLX. Slower to start than Kokoro, but supports emotion and voice cloning. Requires macOS 15+ and Apple Silicon.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    case .server:
                        SettingsRow("Server URL") {
                            TextField("http://localhost:8880", text: $voice.serverURL)
                                .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                        }
                        SettingsRow("Voice ID") {
                            TextField("af_heart", text: $voice.serverVoice)
                                .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                        }
                        Text("Any OpenAI-compatible /v1/audio/speech endpoint — kokoro-fastapi or a CosyVoice server.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // ── 3. Voice ──────────────────────────────────
                SettingsCard(title: "Voice", icon: "person.wave.2.fill") {
                    switch voice.engine {
                    case .system:
                        Picker("", selection: $voice.systemVoiceID) {
                            Text("Default").tag("")
                            ForEach(voice.availableSystemVoices, id: \.identifier) { v in
                                Text("\(v.name) — \(qualityLabel(v.quality))").tag(v.identifier)
                            }
                        }
                        .labelsHidden()
                        HStack {
                            Text("Speed").font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                            Slider(value: $voice.speechRate, in: 0.35...0.65)
                        }
                        Text("Better voices: System Settings → Accessibility → Spoken Content → Manage Voices (look for Premium).")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)

                    case .kokoro:
                        Picker("", selection: $voice.kokoroVoice) {
                            ForEach(KokoroEngine.voices, id: \.id) { v in Text(v.label).tag(v.id) }
                        }
                        .labelsHidden()

                    case .cosyVoice:
                        CosyVoicePicker(voice: voice)

                    case .server:
                        Text("Set by the Voice ID above.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    }

                    Divider().overlay(Theme.border).padding(.vertical, 2)

                    HStack(spacing: 10) {
                        Button {
                            voice.speakNow("Hello Sam, this is Athena. This is how I will sound.")
                        } label: {
                            Label("PREVIEW", systemImage: "play.fill")
                                .font(Theme.label).kerning(1)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.amber).clipShape(Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .disabled(voice.cosyVoice.buildingReference)

                        if voice.isSpeaking {
                            Button { voice.stopSpeaking() } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(Theme.mono(10)).foregroundStyle(Theme.red)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }

                // ── 4. Emotion (CosyVoice only) ───────────────
                if voice.engine.supportsEmotion {
                    SettingsCard(title: "Style & emotion", icon: "theatermasks.fill") {
                        SettingsRow("Default style") {
                            TextField("e.g. warm and concise", text: $voice.cosyInstruction)
                                .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                        }
                        Text("The agent can also tag individual lines — “(happy) Good news!” — and the delivery changes. Unknown tags act as freeform direction.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                        FlowTags(tags: CosyVoiceEngine.emotions)
                        Button("Preview with emotion") {
                            voice.speakNow("(excited) The markets just moved. (calm) But nothing needs your attention right now.")
                        }
                        .font(Theme.mono(11))
                    }
                }

                // ── 5. Microphone ─────────────────────────────
                SettingsCard(title: "Microphone", icon: "mic.fill") {
                    Text("Hold SPACE (with an empty message box) to talk. Press ESC to interrupt Athena.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if voice.permissionDenied {
                        Text("⚠ Microphone or speech recognition denied — enable in System Settings → Privacy & Security.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(voice.sttEngine == .apple
                           ? "Request microphone & speech permissions"
                           : "Request microphone permission") { voice.requestPermissions() }
                        .font(Theme.mono(11))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }
}

/// Titled group box — keeps the settings readable instead of one long column.
struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.amber)
                Text(title.uppercased())
                    .font(Theme.mono(9, weight: .semibold)).kerning(1.2)
                    .foregroundStyle(Theme.amber)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
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
            HStack(spacing: 6) {
                Text("Use a Kokoro voice as the reference")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                Spacer()
            }

            // Live step-by-step feedback — this can take a minute the first
            // time, since it may download Kokoro before synthesizing.
            if voice.cosyVoice.buildingReference || voice.cosyVoice.referenceStatus != nil {
                HStack(spacing: 7) {
                    if voice.cosyVoice.buildingReference {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(Theme.green)
                    }
                    Text(voice.cosyVoice.referenceStatus ?? "Working…")
                        .font(Theme.mono(10)).foregroundStyle(Theme.amber)
                    Spacer()
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .transition(.opacity)
            }
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
                            let isSelected = voice.cosyVoice.voiceSampleLabel == candidate.label
                            HStack(spacing: 4) {
                                if isSelected, voice.cosyVoice.buildingReference {
                                    ProgressView().controlSize(.small).scaleEffect(0.4)
                                        .frame(width: 8, height: 8)
                                } else if isSelected {
                                    Image(systemName: "checkmark").font(.system(size: 7))
                                }
                                Text(candidate.label.components(separatedBy: " (").first
                                     ?? candidate.id)
                                    .font(Theme.mono(10))
                            }
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(isSelected ? Theme.green.opacity(0.18) : Theme.panelAlt)
                            .clipShape(Capsule())
                            .foregroundStyle(isSelected ? Theme.green : Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .disabled(voice.cosyVoice.buildingReference)
                        .opacity(voice.cosyVoice.buildingReference ? 0.5 : 1)
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

            if let failure = voice.cosyVoice.lastFailure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.red)
                    Text(failure).font(Theme.mono(10)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            Text("CosyVoice has no preset voices — you pick one by cloning a 5–15 second reference clip. Borrowing a Kokoro voice needs the Kokoro model downloaded first.")
                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
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
        .animation(.easeInOut(duration: 0.2), value: voice.cosyVoice.buildingReference)
        .animation(.easeInOut(duration: 0.2), value: voice.cosyVoice.referenceStatus)
    }
}

/// Status + load/unload for the embedded Kokoro model.
struct KokoroStatusRow: View {
    @ObservedObject var kokoro: KokoroEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModelDownloadRow(
                phase: kokoro.phase,
                downloadTitle: "Download & load model (330 MB)",
                onStart: { Task { await kokoro.prepare() } },
                onRetry: { Task { await kokoro.retry() } })

            HStack(spacing: 12) {
                Button(kokoro.isDownloaded ? "Load model" : "Download & load model") {
                    Task { await kokoro.prepare() }
                }
                .disabled(kokoro.status.isBusy)

                if kokoro.isDownloaded {
                    Button("Unload") { kokoro.unload() }.disabled(kokoro.status.isBusy)
                    Button("Reveal files") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: KokoroEngine.assetDirectory.path)
                    }
                    Button("Free memory") {
                        MLXMemory.flush()
                        NSLog("[memory] after flush — %@", MLXMemory.footprint)
                    }
                    .help("Releases cached GPU buffers without unloading the model")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: kokoro.status)
    }
}

/// Status + load/unload for the embedded CosyVoice model.
/// Download/load state for the Parakeet speech-to-text model, plus the
/// model-version picker (which lives here so it can bind to the engine
/// object directly).
struct ParakeetStatusRow: View {
    @ObservedObject var stt: ParakeetSTT

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModelDownloadRow(
                phase: stt.phase,
                detail: stt.progressDetail,
                downloadTitle: "Download model (600 MB)",
                onStart: { Task { await stt.downloadAndLoad() } },
                onRetry: { Task { await stt.downloadAndLoad() } })

            if stt.downloadedBytes > 0 {
                HStack(spacing: 12) {
                    Button("Clear download") { stt.deleteDownload() }
                        .help("Deletes the cached model. Use this if a download was interrupted — a partial bundle loads and then fails confusingly.")
                    Button("Reveal cache") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: ParakeetSTT.cacheDirectory.path)
                    }
                }
                .font(Theme.mono(10))
            }

            Divider().overlay(Theme.border).padding(.vertical, 2)

            SectionLabel(text: "Model")
            Picker("", selection: $stt.modelVersion) {
                ForEach(ParakeetSTT.ModelVersion.allCases) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .labelsHidden()
            .disabled(stt.status.isBusy)
            Text("Switching model discards the loaded one and downloads the other on next use.")
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.2), value: stt.status)
    }
}

struct CosyStatusRow: View {
    @ObservedObject var cosy: CosyVoiceEngine
    let variant: CosyVoiceEngine.Variant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModelDownloadRow(
                phase: cosy.phase,
                detail: cosy.progressDetail,
                downloadTitle: "Download & load model",
                onStart: { Task { await cosy.prepare(variant: variant) } },
                onRetry: { Task { await cosy.retry(variant: variant) } })

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
