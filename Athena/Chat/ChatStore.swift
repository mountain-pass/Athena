import Foundation
import Combine
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    let id: String
    let role: Role
    var text: String
    var viaVoice = false
    var attachmentNames: [String] = []
    var streaming = false
    let date: Date
    /// Raw tool/search payloads — collapsed in the UI and never spoken.
    var isToolNoise = false
    /// Reply to a spoken turn — rendered as a compact "Voice response" bubble
    /// (expandable), with the full text going to TTS.
    var isVoiceReply = false

    init(id: String = UUID().uuidString, role: Role, text: String, viaVoice: Bool = false,
         attachmentNames: [String] = [], streaming: Bool = false, date: Date = .now,
         isToolNoise: Bool = false, isVoiceReply: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.viaVoice = viaVoice
        self.attachmentNames = attachmentNames; self.streaming = streaming; self.date = date
        self.isToolNoise = isToolNoise; self.isVoiceReply = isVoiceReply
    }

    var byteLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    }

    /// Deterministic id for a history row.
    ///
    /// Critical for scroll stability: generating a fresh UUID on every history
    /// refresh made SwiftUI treat every message as brand new, tearing down and
    /// rebuilding the list several times a second — which is what made the
    /// transcript bounce while the agent was working.
    static func stableID(index: Int, text: String) -> String {
        "h\(index)-\(text.hashValue)"
    }

    /// Detects machine payloads that shouldn't be read as conversation:
    /// web-search dumps, JSON blobs, untrusted-content envelopes.
    static func looksLikeToolNoise(_ text: String) -> Bool {
        if text.contains("EXTERNAL_UNTRUSTED_CONTENT") { return true }
        if text.contains("\"siteName\"") || text.contains("\"snippet\"") { return true }
        if text.contains("<<<") && text.contains(">>>") { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")), trimmed.count > 400 { return true }
        // Mostly-JSON heuristic for long blobs.
        if trimmed.count > 1500 {
            let quotes = trimmed.filter { $0 == "\"" }.count
            if Double(quotes) / Double(trimmed.count) > 0.02 { return true }
        }
        return false
    }
}

/// Owns the main chat session: sends messages, ingests streamed gateway events,
/// loads history on (re)connect, and triggers TTS for voice-initiated turns.
@MainActor
final class ChatStore: ObservableObject {
    /// Full transcript. The UI renders only a window of this (see `messages`)
    /// so a long history can't bog down or crash the view.
    @Published private(set) var allMessages: [ChatMessage] = []
    /// How many recent messages are currently rendered.
    @Published private(set) var visibleCount = 20

    /// The slice SwiftUI actually draws.
    var messages: [ChatMessage] {
        allMessages.suffix(visibleCount).map { $0 }
    }
    var hasOlderMessages: Bool { allMessages.count > visibleCount }

    func loadOlder(step: Int = 20) {
        guard hasOlderMessages, !loadingOlder else { return }
        loadingOlder = true
        // Deferred so this can never mutate state during a view update.
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) {
                visibleCount = min(visibleCount + step, allMessages.count)
            }
            loadingOlder = false
        }
    }
    private var loadingOlder = false

    /// Resets the window when the transcript is replaced wholesale.
    private func clampVisibleCount() {
        if visibleCount > allMessages.count {
            visibleCount = max(20, allMessages.count)
        }
    }

    @Published private(set) var agentBusy = false
    @Published var pendingAttachments: [ChatAttachment] = []
    /// Number of attachments currently being read/converted off-main.
    @Published private(set) var attachmentsLoading = 0

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
    private var streamingSpeechStarted = false
    /// Index in `allMessages` at which the current turn's reply must appear.
    /// Without this, a history refresh can hand TTS the PREVIOUS answer.
    private var turnAnchorIndex = 0
    private var historyRefreshTask: Task<Void, Never>?

    init(gateway: GatewayClient, voice: VoiceManager) {
        self.gateway = gateway
        self.voice = voice

        gateway.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: Attachment loading (always off the main thread)

    func beginAttachmentLoad() { attachmentsLoading += 1 }

    func finishAttachmentLoad(_ attachment: ChatAttachment?) {
        attachmentsLoading = max(0, attachmentsLoading - 1)
        if let attachment {
            pendingAttachments.append(attachment)
        } else {
            allMessages.append(ChatMessage(role: .system, text: "Could not read that attachment."))
        }
    }

    // MARK: Sending

    /// Marker prepended to spoken turns. The full contract lives in the agent's
    /// AGENTS.md (written by AgentProvisioner) — this just flags the mode, so
    /// we don't burn tokens restating the rules on every message.
    static let voiceMarker = "[voice]"

    /// Used when the agent hasn't been provisioned yet: spells out the rules
    /// inline so voice still sounds right on an unconfigured gateway.
    static let voiceDirectiveFallback = """
        [voice] (The user spoke this and will hear your reply via text-to-speech. \
        Reply in plain speakable sentences — no markdown, headings, bullets, \
        emoji, code or URLs. Keep it brief and natural.)
        """

    /// Set true once AgentProvisioner has written the manual to the workspace.
    var agentProvisioned = UserDefaults.standard.bool(forKey: "agent.provisioned") {
        didSet { UserDefaults.standard.set(agentProvisioned, forKey: "agent.provisioned") }
    }

    var useVoiceDirective = UserDefaults.standard.object(forKey: "voice.directive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useVoiceDirective, forKey: "voice.directive") }
    }

    func send(text: String, viaVoice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return }
        let atts = pendingAttachments
        pendingAttachments = []
        currentTurnViaVoice = viaVoice
        agentBusy = true
        turnCharCount = 0
        turnStarted = .now
        // Anything before this point belongs to earlier turns.
        turnAnchorIndex = allMessages.count + 1   // +1 for the user row we append next
        // The bubble shows only what the user said; the directive rides along
        // to the agent invisibly.
        allMessages.append(ChatMessage(role: .user, text: trimmed, viaVoice: viaVoice,
                                    attachmentNames: atts.map(\.fileName)))
        let payload: String
        if viaVoice && useVoiceDirective {
            let prefix = agentProvisioned ? Self.voiceMarker : Self.voiceDirectiveFallback
            payload = "\(prefix)\n\n\(trimmed)"
        } else {
            payload = trimmed
        }
        Task {
            do {
                _ = try await gateway.chatSend(payload, attachments: atts)
            } catch {
                self.agentBusy = false
                self.allMessages.append(ChatMessage(role: .system, text: "Send failed: \(error.localizedDescription)"))
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
            for (index, row) in rows.enumerated() {
                guard let text = Self.extractText(row), !text.isEmpty else { continue }
                let roleStr = row["role"]?.stringValue ?? row["sender"]?.stringValue ?? "assistant"
                let role: ChatMessage.Role = (roleStr == "user") ? .user : .assistant
                let display = role == .user ? Self.stripVoiceMarker(text) : text
                loaded.append(ChatMessage(id: ChatMessage.stableID(index: index, text: text),
                                          role: role, text: display,
                                          viaVoice: role == .user && display != text,
                                          isToolNoise: ChatMessage.looksLikeToolNoise(text)))
            }
            if !loaded.isEmpty { self.allMessages = loaded }
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
            // Short debounce — this is the main source of perceived latency
            // when live event parsing misses the reply.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await refreshFromHistory()
        }
    }

    private func refreshFromHistory() async {
        guard let history = try? await gateway.chatHistory() else { return }
        let rows = history["messages"]?.arrayValue ?? history.arrayValue ?? []
        var loaded: [ChatMessage] = []
        for (index, row) in rows.enumerated() {
            guard let text = Self.extractText(row), !text.isEmpty else { continue }
            let roleStr = row["role"]?.stringValue ?? row["sender"]?.stringValue
                ?? row["author"]?.stringValue ?? "assistant"
            let isUser = roleStr == "user"
            let display = isUser ? Self.stripVoiceMarker(text) : text
            loaded.append(ChatMessage(id: ChatMessage.stableID(index: index, text: text),
                                      role: isUser ? .user : .assistant,
                                      text: display,
                                      viaVoice: isUser && display != text,
                                      isToolNoise: ChatMessage.looksLikeToolNoise(text)))
        }
        guard !loaded.isEmpty,
              loaded.count >= allMessages.filter({ $0.role != .system }).count else { return }

        // Only publish when something actually changed — otherwise SwiftUI
        // rebuilds the list for nothing and the view jumps.
        let sameCount = loaded.count == allMessages.count
        let sameContent = sameCount && zip(loaded, allMessages).allSatisfy {
            $0.id == $1.id && $0.text == $1.text
        }
        guard !sameContent else {
            if agentBusy, let last = loaded.last, last.role == .assistant {
                turnCharCount = max(turnCharCount, last.text.count)
                finishTurn()
            }
            return
        }

        allMessages = loaded
        clampVisibleCount()
        if agentBusy, let last = loaded.last, last.role == .assistant {
            turnCharCount = max(turnCharCount, last.text.count)
            finishTurn()
        }
    }

    private func ingestAssistantUpdate(_ payload: JSONValue) {
        // Only the main session belongs in this transcript — background
        // sessions (source suggestions, config lookups) stay invisible.
        if let sk = payload["sessionKey"]?.stringValue, sk != GatewayClient.mainSessionKey {
            return   // config / todo side-sessions stay out of the transcript
        }
        // Ignore echoes of our own user messages.
        let role = payload["role"]?.stringValue ?? payload["message"]?["role"]?.stringValue
        if role == "user" { return }
        // Tool results belong in the Live Cognition panel, not the transcript.
        if role == "tool" || payload["tool"] != nil || payload["toolName"] != nil
            || payload["toolResult"] != nil { return }
        guard let text = Self.extractText(payload), !text.isEmpty else {
            // No text — could be a lifecycle marker (turn end).
            if payload["state"]?.stringValue == "final" || payload["done"]?.boolValue == true {
                finishTurn()
            }
            return
        }
        if agentBusy { turnCharCount = max(turnCharCount, text.count) }

        // Speak as the reply arrives — but only the reply to THIS turn.
        // A history refresh can deliver the previous answer; without the
        // anchor check we'd read it aloud again.
        let belongsToThisTurn = allMessages.count >= turnAnchorIndex
        if currentTurnViaVoice, agentBusy, belongsToThisTurn {
            if !streamingSpeechStarted {
                streamingSpeechStarted = true
                voice.beginStreamingSpeech()
            }
            voice.appendStreamingSpeech(fullTextSoFar: text)
        }
        let isFinal = payload["state"]?.stringValue != "delta"
        if let last = allMessages.last, last.role == .assistant, last.streaming {
            allMessages[allMessages.count - 1].text = text
            if isFinal { allMessages[allMessages.count - 1].streaming = false; finishTurn() }
        } else {
            allMessages.append(ChatMessage(role: .assistant, text: text, streaming: !isFinal,
                                           isToolNoise: ChatMessage.looksLikeToolNoise(text)))
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
        // Speak the last real reply from THIS turn — never a tool payload,
        // and never an answer from an earlier exchange.
        if currentTurnViaVoice,
           let idx = allMessages.lastIndex(where: { $0.role == .assistant && !$0.isToolNoise }),
           idx >= turnAnchorIndex - 1 {
            allMessages[idx].isVoiceReply = true
            if streamingSpeechStarted {
                // Already speaking — just flush whatever wasn't covered.
                voice.endStreamingSpeech(fullText: allMessages[idx].text)
            } else {
                voice.speak(allMessages[idx].text)
            }
        }
        streamingSpeechStarted = false
        currentTurnViaVoice = false
    }

    /// Removes the invisible protocol prefix so the user's bubble shows only
    /// what they actually said.
    static func stripVoiceMarker(_ text: String) -> String {
        var out = text
        if out.hasPrefix(voiceMarker) {
            out = String(out.dropFirst(voiceMarker.count))
        } else if out.hasPrefix("[voice]") {
            out = String(out.dropFirst("[voice]".count))
            // The fallback directive adds a parenthetical — drop that too.
            if out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("("),
               let close = out.firstIndex(of: ")") {
                out = String(out[out.index(after: close)...])
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
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
