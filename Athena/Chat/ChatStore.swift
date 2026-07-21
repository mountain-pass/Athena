import Foundation
import Combine

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    let id: UUID
    let role: Role
    var text: String
    var viaVoice = false
    var attachmentNames: [String] = []
    var streaming = false
    let date: Date

    init(id: UUID = UUID(), role: Role, text: String, viaVoice: Bool = false,
         attachmentNames: [String] = [], streaming: Bool = false, date: Date = .now) {
        self.id = id; self.role = role; self.text = text; self.viaVoice = viaVoice
        self.attachmentNames = attachmentNames; self.streaming = streaming; self.date = date
    }
}

/// Owns the main chat session: sends messages, ingests streamed gateway events,
/// loads history on (re)connect, and triggers TTS for voice-initiated turns.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var agentBusy = false
    @Published var pendingAttachments: [ChatAttachment] = []

    // Live generation stats (chars ≈ tokens × 4)
    @Published private(set) var turnCharCount = 0
    @Published private(set) var turnStarted: Date?
    @Published private(set) var lastTokPerSec: Double = 0
    @Published private(set) var totalTurnTokens = 0

    /// Live tokens/second while the agent streams; last turn's rate when idle.
    var tokensPerSecond: Double {
        guard agentBusy, let start = turnStarted else { return lastTokPerSec }
        let elapsed = max(0.5, Date().timeIntervalSince(start))
        return Double(turnCharCount) / 4.0 / elapsed
    }

    private let gateway: GatewayClient
    private let voice: VoiceManager
    private var cancellables = Set<AnyCancellable>()
    /// True while the current agent turn was started by voice → speak the reply.
    private var currentTurnViaVoice = false
    private var historyRefreshTask: Task<Void, Never>?

    init(gateway: GatewayClient, voice: VoiceManager) {
        self.gateway = gateway
        self.voice = voice

        gateway.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: Sending

    func send(text: String, viaVoice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return }
        let atts = pendingAttachments
        pendingAttachments = []
        currentTurnViaVoice = viaVoice
        agentBusy = true
        turnCharCount = 0
        turnStarted = .now
        messages.append(ChatMessage(role: .user, text: trimmed, viaVoice: viaVoice,
                                    attachmentNames: atts.map(\.fileName)))
        Task {
            do {
                _ = try await gateway.chatSend(trimmed, attachments: atts)
            } catch {
                self.agentBusy = false
                self.messages.append(ChatMessage(role: .system, text: "Send failed: \(error.localizedDescription)"))
            }
        }
    }

    func abort() {
        Task { try? await gateway.chatAbort(); agentBusy = false }
    }

    // MARK: History

    func loadHistory() {
        Task {
            guard let history = try? await gateway.chatHistory() else { return }
            let rows = history["messages"]?.arrayValue ?? history.arrayValue ?? []
            var loaded: [ChatMessage] = []
            for row in rows {
                guard let text = Self.extractText(row), !text.isEmpty else { continue }
                let roleStr = row["role"]?.stringValue ?? row["sender"]?.stringValue ?? "assistant"
                let role: ChatMessage.Role = (roleStr == "user") ? .user : .assistant
                loaded.append(ChatMessage(role: role, text: text))
            }
            if !loaded.isEmpty { self.messages = loaded }
        }
    }

    // MARK: Event ingestion
    // Gateway pushes `chat` / `agent` / `session.message` events while a run is
    // active. Payload shapes vary by event family, so extraction is tolerant.

    private func handle(_ event: GatewayEvent) {
        switch event.name {
        case "athena.connected":
            loadHistory()
        case "chat", "agent":
            ingestAssistantUpdate(event.payload)
            scheduleHistoryRefresh()
        default:
            if event.name.hasPrefix("session.") {
                ingestAssistantUpdate(event.payload)
                scheduleHistoryRefresh()
            }
        }
    }

    /// Source-of-truth fallback: event payload shapes vary between gateway
    /// versions, so after agent activity settles (800ms quiet), re-pull
    /// `chat.history` — documented and display-normalized for UI clients.
    private func scheduleHistoryRefresh() {
        historyRefreshTask?.cancel()
        historyRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await refreshFromHistory()
        }
    }

    private func refreshFromHistory() async {
        guard let history = try? await gateway.chatHistory() else { return }
        let rows = history["messages"]?.arrayValue ?? history.arrayValue ?? []
        var loaded: [ChatMessage] = []
        for row in rows {
            guard let text = Self.extractText(row), !text.isEmpty else { continue }
            let roleStr = row["role"]?.stringValue ?? row["sender"]?.stringValue
                ?? row["author"]?.stringValue ?? "assistant"
            loaded.append(ChatMessage(role: roleStr == "user" ? .user : .assistant, text: text))
        }
        guard !loaded.isEmpty, loaded.count >= messages.filter({ $0.role != .system }).count else { return }
        messages = loaded
        if agentBusy, let last = loaded.last, last.role == .assistant {
            turnCharCount = max(turnCharCount, last.text.count)
            finishTurn()
        }
    }

    private func ingestAssistantUpdate(_ payload: JSONValue) {
        // Ignore echoes of our own user messages.
        let role = payload["role"]?.stringValue ?? payload["message"]?["role"]?.stringValue
        if role == "user" { return }
        guard let text = Self.extractText(payload), !text.isEmpty else {
            // No text — could be a lifecycle marker (turn end).
            if payload["state"]?.stringValue == "final" || payload["done"]?.boolValue == true {
                finishTurn()
            }
            return
        }
        if agentBusy { turnCharCount = max(turnCharCount, text.count) }
        let isFinal = payload["state"]?.stringValue != "delta"
        if let last = messages.last, last.role == .assistant, last.streaming {
            messages[messages.count - 1].text = text
            if isFinal { messages[messages.count - 1].streaming = false; finishTurn() }
        } else {
            messages.append(ChatMessage(role: .assistant, text: text, streaming: !isFinal))
            if isFinal { finishTurn() }
        }
    }

    private func finishTurn() {
        guard agentBusy else { return }
        if let start = turnStarted {
            let elapsed = max(0.5, Date().timeIntervalSince(start))
            lastTokPerSec = Double(turnCharCount) / 4.0 / elapsed
            totalTurnTokens += turnCharCount / 4
        }
        agentBusy = false
        if currentTurnViaVoice, let reply = messages.last(where: { $0.role == .assistant })?.text {
            voice.speak(reply)
        }
        currentTurnViaVoice = false
    }

    /// Pulls display text out of the several shapes gateway events/history use.
    static func extractText(_ v: JSONValue) -> String? {
        if let s = v["text"]?.stringValue { return s }
        if let s = v["delta"]?.stringValue { return s }
        if let s = v["content"]?.stringValue { return s }
        if let parts = v["content"]?.arrayValue, let s = joinParts(parts) { return s }
        if let s = v["message"]?.stringValue { return s }
        if let m = v["message"] {
            if let s = m["text"]?.stringValue ?? m["content"]?.stringValue { return s }
            if let parts = m["content"]?.arrayValue, let s = joinParts(parts) { return s }
        }
        return nil
    }

    private static func joinParts(_ parts: [JSONValue]) -> String? {
        let joined = parts
            .compactMap { $0["text"]?.stringValue ?? $0.stringValue }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
