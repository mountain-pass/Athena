import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var chat: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
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

    private var isUser: Bool { message.role == .user }

    var body: some View {
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
                Text(message.text.isEmpty && message.streaming ? "…" : message.text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
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
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if !chat.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.pendingAttachments) { att in
                            Label(att.fileName, systemImage: iconFor(att.kind))
                                .font(Theme.mono(10))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.panelAlt).clipShape(Capsule())
                                .foregroundStyle(Theme.textDim)
                        }
                        Button("Clear") { chat.pendingAttachments = [] }
                            .font(Theme.mono(10)).buttonStyle(.plain).foregroundStyle(Theme.red)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }

            HStack(spacing: 10) {
                Button { showImporter = true } label: {
                    Image(systemName: "plus.circle").foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .help("Attach image, video, or file")

                TextField(textFocused ? "Type a message…" : "Type here — or hold SPACE to talk",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .focused($textFocused)
                    .lineLimit(1...5)
                    .onSubmit(sendDraft)

                // Mic: click-to-toggle alternative to holding space
                Button {
                    if voice.state == .listening { voice.stopListeningAndSend() }
                    else { voice.startListening() }
                } label: {
                    Image(systemName: voice.state == .listening ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(voice.state == .listening ? Theme.amber : Theme.textDim)
                }
                .buttonStyle(.plain)

                if chat.agentBusy {
                    Button { chat.abort() } label: {
                        Image(systemName: "stop.circle").foregroundStyle(Theme.red)
                    }.buttonStyle(.plain)
                }

                Button(action: sendDraft) {
                    Text("SEND").font(Theme.label).kerning(1)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                          && chat.pendingAttachments.isEmpty)
            }
            .padding(12)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.image, .movie, .audio, .pdf, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { addAttachment(url) }
        }
    }

    private func sendDraft() {
        chat.send(text: draft, viaVoice: false)
        draft = ""
    }

    private func addAttachment(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: ChatAttachment.Kind =
            type.conforms(to: .image) ? .image :
            type.conforms(to: .movie) ? .video :
            type.conforms(to: .audio) ? .audio : .file
        chat.pendingAttachments.append(ChatAttachment(
            kind: kind, fileName: url.lastPathComponent,
            mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data))
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
