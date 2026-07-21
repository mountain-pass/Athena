import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var chat: ChatStore
    private let bottomAnchor = "athena.chat.bottom"
    /// Throttles auto-scroll while text streams (4×/sec instead of per delta).
    private let streamTick = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    /// Length of the last message at the previous scroll — used to detect real growth.
    @State private var lastLength = 0

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !chat.messages.isEmpty else { return }
        // Hop out of the current update cycle — scrolling (or mutating state)
        // mid-render is what causes the crashes.
        Task { @MainActor in
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // Explicit control only. Auto-loading from .onAppear
                        // mutates state during a view update and re-triggers
                        // itself — that combination crashes SwiftUI.
                        if chat.hasOlderMessages {
                            Button {
                                chat.loadOlder()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.circle")
                                    Text("Load \(min(20, chat.allMessages.count - chat.visibleCount)) older messages")
                                }
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.textDim)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                                .transition(.opacity)
                        }
                        // Stable bottom anchor — scrolling to the last message
                        // id misses partial content while streaming.
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(16)
                }
                // Scroll only when the transcript actually grows — never on a
                // bare timer, which is what made the view bounce.
                .onChange(of: chat.allMessages.count) { _, _ in
                    lastLength = chat.messages.last?.text.count ?? 0
                    scrollToBottom(proxy)
                }
                .onReceive(streamTick) { _ in
                    guard chat.agentBusy else { return }
                    let length = chat.messages.last?.text.count ?? 0
                    guard length > lastLength else { return }   // no growth, no scroll
                    lastLength = length
                    scrollToBottom(proxy, animated: false)
                }
                .onAppear {
                    lastLength = chat.messages.last?.text.count ?? 0
                    scrollToBottom(proxy, animated: false)
                }
            }
            Divider().overlay(Theme.border)
            InputBar(chat: chat)
        }
        .panel()
    }
}

// MARK: Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    @State private var expanded = false

    private var isUser: Bool { message.role == .user }

    @EnvironmentObject var voice: VoiceManager

    var body: some View {
        if message.isToolNoise {
            toolNoiseRow
        } else if message.isVoiceReply {
            voiceReplyBubble
        } else {
            standardBubble
        }
    }

    /// Spoken replies stay compact — the audio IS the response. Click to read.
    private var voiceReplyBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Theme.blue.opacity(0.15)).frame(width: 30, height: 30)
                        Image(systemName: voice.isSpeaking ? "speaker.wave.2.fill" : "waveform")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.blue)
                            .symbolEffect(.variableColor.iterative, isActive: voice.isSpeaking)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice response")
                            .font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(voice.isSpeaking ? "speaking… · ESC to stop"
                                              : "~\(max(1, message.text.count / 850)) min · click to read")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer(minLength: 12)
                    if voice.isSpeaking {
                        Button { voice.stopSpeaking() } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 16)).foregroundStyle(Theme.red)
                        }.buttonStyle(.plain)
                    } else {
                        Button { voice.speakNow(message.text) } label: {
                            Image(systemName: "play.circle")
                                .font(.system(size: 16)).foregroundStyle(Theme.textDim)
                        }.buttonStyle(.plain).help("Replay")
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.bg.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(voice.isSpeaking ? Theme.blue.opacity(0.5) : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                RichMessageView(text: message.text)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.bg.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 60)
    }

    /// Raw tool/search payloads collapse to a single quiet line.
    private var toolNoiseRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 9))
                    Text("Tool output · \(message.byteLabel)")
                        .font(Theme.mono(10))
                    Text(expanded ? "hide" : "show")
                        .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                }
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.panelAlt.opacity(0.6))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(message.text)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Theme.bg.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var standardBubble: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isUser ? "YOU" : message.role == .assistant ? "ATHENA" : "SYSTEM")
                        .font(Theme.label).kerning(1)
                        .foregroundStyle(isUser ? Theme.amber : Theme.textFaint)
                    if message.viaVoice {
                        Label("VOICE", systemImage: "waveform")
                            .font(Theme.label).foregroundStyle(Theme.textFaint)
                    }
                }
                Group {
                    if isUser || message.streaming {
                        // Users type plain text; streaming text renders raw
                        // until final (re-parsing every delta would be wasteful).
                        Text(message.text.isEmpty && message.streaming ? "…" : message.text)
                            .font(Theme.body)
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    } else {
                        // Final assistant replies get the rich renderer:
                        // markdown, code boxes, pretty JSON, HTML preview.
                        RichMessageView(text: message.text)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(isUser ? Theme.panelAlt : Theme.bg.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                ForEach(message.attachmentNames, id: \.self) { name in
                    Label(name, systemImage: "paperclip")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                }
            }
            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: Input bar — text, attachments (image/video/file), mic

struct InputBar: View {
    @ObservedObject var chat: ChatStore
    @EnvironmentObject var voice: VoiceManager
    @State private var draft = ""
    @State private var showImporter = false
    @State private var pasteMonitor: Any?
    @State private var dropTargeted = false
    @State private var inputHeight: CGFloat = 20

    var body: some View {
        VStack(spacing: 6) {
            if !chat.pendingAttachments.isEmpty || chat.attachmentsLoading > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.pendingAttachments) { att in
                            HStack(spacing: 5) {
                                Image(systemName: iconFor(att.kind))
                                Text(att.fileName).lineLimit(1)
                                Text(att.byteLabel).foregroundStyle(Theme.textFaint)
                            }
                            .font(Theme.mono(10))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.panelAlt).clipShape(Capsule())
                            .foregroundStyle(Theme.textDim)
                        }
                        if chat.attachmentsLoading > 0 {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                                Text("reading \(chat.attachmentsLoading)…").font(Theme.mono(10))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.panelAlt).clipShape(Capsule())
                            .foregroundStyle(Theme.textDim)
                        }
                        if !chat.pendingAttachments.isEmpty {
                            Button("Clear") { chat.pendingAttachments = [] }
                                .font(Theme.mono(10)).buttonStyle(.plain).foregroundStyle(Theme.red)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button { showImporter = true } label: {
                    Image(systemName: "plus.circle").foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .help("Attach image, video, or file")
                .padding(.bottom, 2)

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Type here — or hold SPACE to talk")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textFaint)
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                            .padding(.top, 3)
                    }
                    MultilineTextInput(text: $draft,
                                       height: $inputHeight,
                                       onSubmit: sendDraft)
                        .frame(height: inputHeight)
                }

                // Mic: click-to-toggle alternative to holding space
                Button {
                    if voice.state == .listening {
                        voice.stopListeningAndSend()
                    } else if voice.canListen {
                        voice.startListening()
                    } else {
                        voice.requestPermissions()
                    }
                } label: {
                    Image(systemName: voice.state == .listening ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(voice.state == .listening ? Theme.amber : Theme.textDim)
                }
                .buttonStyle(.plain)
                .help(voice.canListen ? "Click to talk (or hold SPACE)"
                                      : "Grant microphone access")

                if voice.isSpeaking {
                    Button { voice.stopSpeaking() } label: {
                        Label("STOP", systemImage: "speaker.slash.fill")
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.red.opacity(0.9)).clipShape(Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Stop speaking (or press ESC)")
                }

                if chat.agentBusy {
                    Button { chat.abort() } label: {
                        Image(systemName: "stop.circle").foregroundStyle(Theme.red)
                    }.buttonStyle(.plain).help("Abort the current turn")
                }

                VStack(alignment: .trailing, spacing: 3) {
                    Button(action: sendDraft) {
                        Text("SEND").font(Theme.label).kerning(1)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                              && chat.pendingAttachments.isEmpty)
                    if draft.contains("\n") || draft.count > 40 {
                        Text("⇧↵ newline")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    }
                }
            }
            .padding(12)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.image, .movie, .audio, .pdf, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { addAttachment(url) }
        }
        // Drag files straight onto the input bar.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in addAttachment(url) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.amber, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
            }
        }
        // ⌘V — paste screenshots/images. Text paste falls through to the field.
        .onAppear {
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
                return pasteAttachmentFromClipboard() ? nil : event
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    /// Pulls an image/file off the pasteboard. Returns true if it consumed the
    /// paste (so plain-text pastes still reach the text field normally).
    ///
    /// NSPasteboard must be read on the main thread, but that's just a buffer
    /// copy; all decoding/conversion happens off-main in ChatAttachment.
    @discardableResult
    private func pasteAttachmentFromClipboard() -> Bool {
        let pb = NSPasteboard.general

        // 1. Files copied in Finder
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            for url in urls { addAttachment(url) }
            return true
        }

        // 2. Raw image data (screenshots, images copied from a browser)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pb.data(forType: type) else { continue }
            chat.beginAttachmentLoad()
            Task {
                let att = await ChatAttachment.fromPasteboardImage(
                    data: data, isPNG: type == .png)
                chat.finishAttachmentLoad(att)
            }
            return true
        }

        return false
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !chat.pendingAttachments.isEmpty else { return }
        chat.send(text: trimmed, viaVoice: false)
        draft = ""
        inputHeight = 20
    }

    /// Never reads the file on the main thread — a large video would hang the UI.
    private func addAttachment(_ url: URL) {
        chat.beginAttachmentLoad()
        Task {
            let att = await ChatAttachment.load(from: url)
            chat.finishAttachmentLoad(att)
        }
    }

    private func iconFor(_ kind: ChatAttachment.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .file: "doc"
        }
    }
}
