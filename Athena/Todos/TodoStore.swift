import Foundation
import SwiftUI
import Combine

/// Shared todo list between the user and the agent.
///
/// **Single-writer design.** Athena owns `athena/todos.json` — it's the only
/// thing that rewrites it, so a user edit can never be clobbered. The agent
/// only *appends* to `athena/todo-log.jsonl`; the app replays that log,
/// merges progress/questions/status in, and writes the canonical file back.
@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = [] { didSet { persistLocal() } }
    @Published private(set) var syncing = false
    @Published var lastError: String?

    static let todosPath = "athena/todos.json"
    static let logPath = "athena/todo-log.jsonl"

    private let gateway: GatewayClient
    private lazy var files = WorkspaceFiles(gateway: gateway)
    private var pollTimer: Timer?
    /// Set when a save happened while offline.
    private var pendingPush = false
    private var consumedLogLines = 0
    /// Cleared once we learn the gateway can't serve the log file.
    private var logFileUsable = true

    /// Visible ordering: needs-attention first, then agent work, then the rest.
    var sorted: [TodoItem] {
        items.filter { !$0.done }.sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if (a.owner == .athena) != (b.owner == .athena) { return a.owner == .athena }
            return a.createdAt > b.createdAt
        }
    }
    var completed: [TodoItem] { items.filter(\.done).sorted { $0.updatedAt > $1.updatedAt } }
    var attentionCount: Int { items.filter { !$0.done && $0.needsAttention }.count }

    init(gateway: GatewayClient) {
        self.gateway = gateway
        loadLocal()
    }

    // MARK: Local persistence (instant; gateway sync follows)

    private var localURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Athena/todos.json")
    }

    private func loadLocal() {
        guard let data = try? Data(contentsOf: localURL),
              let saved = try? JSONDecoder().decode([TodoItem].self, from: data) else { return }
        items = saved
    }

    private func persistLocal() {
        let snapshot = items
        let url = localURL
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url) }
        }
    }

    // MARK: CRUD

    func add(title: String, owner: TodoItem.Owner, notes: String = "") {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = TodoItem(title: trimmed, owner: owner)
        item.notes = notes
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
            items.insert(item, at: 0)
        }
        pushToAgent()
        // Delegated work starts immediately — tell the agent about it.
        if owner == .athena { brief(item) }
    }

    func update(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        updated.updatedAt = .now
        items[index] = updated
        pushToAgent()
    }

    func toggleDone(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            items[index].done.toggle()
            items[index].updatedAt = .now
        }
        pushToAgent()
    }

    func delete(_ item: TodoItem) {
        withAnimation(.easeInOut(duration: 0.25)) {
            items.removeAll { $0.id == item.id }
        }
        pushToAgent()
    }

    func clearCompleted() {
        withAnimation(.easeInOut(duration: 0.3)) {
            items.removeAll(where: \.done)
        }
        pushToAgent()
    }

    func answer(question: AgentQuestion, on item: TodoItem, with reply: String) {
        guard let itemIndex = items.firstIndex(where: { $0.id == item.id }),
              let qIndex = items[itemIndex].questions.firstIndex(where: { $0.id == question.id })
        else { return }
        withAnimation {
            items[itemIndex].questions[qIndex].answer = reply
            items[itemIndex].questions[qIndex].answeredAt = .now
            if items[itemIndex].openQuestions.isEmpty,
               items[itemIndex].status == .waitingOnUser {
                items[itemIndex].status = .working
            }
        }
        pushToAgent()
        // Hand the answer back and let it carry on — in the background.
        dispatch(sessionKey: Self.sessionKey(for: item),
                 message: """
                    [todo-answer] Task "\(item.title)" (id \(item.id)).
                    You asked: \(question.text)
                    My answer: \(reply)
                    Continue. Report with PROGRESS: / QUESTION: / STATUS: lines.
                    """,
                 todoId: item.id)
    }

    /// Each delegated task runs in its **own** session, so tasks execute
    /// independently and never block the main conversation.
    static func sessionKey(for item: TodoItem) -> String {
        "athena-todo-\(item.id.prefix(8))"
    }

    /// Hands an existing task to the agent (used when the owner is switched).
    func delegate(_ item: TodoItem) { brief(item) }

    private func brief(_ item: TodoItem) {
        let message = """
            [todo-assign] You have been assigned this task. Work on it now.

            Task id: \(item.id)
            Title: \(item.title)
            Notes: \(item.notes.isEmpty ? "(none)" : item.notes)

            HOW TO REPORT — put these on their own lines in your replies here.
            Athena parses them and shows them to the user:

              PROGRESS: <one short sentence about what you just did> [45%]
              QUESTION: <ask only if genuinely blocked>
              STATUS: working | waitingOnUser | readyForReview
              RESULT:
              <the actual answer / deliverable — as long as it needs to be>

            Rules:
            - Start now. Use your tools. Report PROGRESS as you go, not only at the end.
            - **You MUST finish with a RESULT: block.** That is the thing the user
              actually asked for — the numbers, the answer, the summary, the draft.
              Progress notes are not a substitute for it.
            - RESULT: goes last, may span many lines, and may use markdown.
            - Then emit STATUS: readyForReview. Never claim completion — the user decides.
            - If blocked, emit QUESTION and STATUS: waitingOnUser instead.
            - Keep PROGRESS lines short; they render in a narrow panel.
            """
        markWorking(item.id)
        dispatch(sessionKey: Self.sessionKey(for: item), message: message,
                 todoId: item.id, createSession: true)
    }

    /// Task ids with an in-flight dispatch — drives the "sending" indicator.
    @Published private(set) var runningTasks: Set<String> = []

    /// Sends work to the agent WITHOUT blocking. An agent turn can take
    /// minutes; nothing in the UI waits on it. Progress arrives via polling,
    /// so the user can close the sheet and the task keeps running.
    private func dispatch(sessionKey key: String, message: String,
                          todoId: String, createSession: Bool = false) {
        runningTasks.insert(todoId)
        let gateway = self.gateway

        Task.detached(priority: .utility) { [weak self] in
            if createSession {
                _ = try? await gateway.request("sessions.create",
                                               .from(["key": key, "title": "Todo task"]))
            }
            _ = try? await gateway.chatSend(message, sessionKey: key)
            await MainActor.run { self?.runningTasks.remove(todoId) }
        }

        // Look for updates shortly after, without holding anything up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.pullAgentUpdates()
        }
    }

    private func markWorking(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation { items[index].status = .working }
    }

    /// Nudges a task that's stalled or needs a push.
    /// Nudges a stalled task. Runs in the background — close the sheet freely.
    func nudge(_ item: TodoItem, instruction: String? = nil) {
        markWorking(item.id)
        let ask = instruction ?? """
            Continue, then finish with a RESULT: block containing the actual \
            answer — not just progress notes.
            """
        dispatch(sessionKey: Self.sessionKey(for: item),
                 message: """
                    [todo-nudge] Task \(item.id) ("\(item.title)").
                    \(ask)
                    Report with PROGRESS: / QUESTION: / STATUS: / RESULT: lines.
                    """,
                 todoId: item.id)
    }

    // MARK: Gateway sync

    func startSync() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Idle when nothing is in flight — no pointless round-trips.
                guard !self.activeTasks.isEmpty || !self.runningTasks.isEmpty else { return }
                await self.pullAgentUpdates()
            }
        }
        Task { await pullAgentUpdates() }
    }

    func stopSync() { pollTimer?.invalidate(); pollTimer = nil }

    /// Called when the gateway comes back — flush anything we deferred.
    func resumeAfterReconnect() {
        if pendingPush { pushToAgent() }
        Task { await pullAgentUpdates() }
    }

    /// Best-effort mirror to the agent workspace. This gateway restricts
    /// `agents.files.*` to bootstrap files, so it usually no-ops — the app is
    /// the source of truth and the agent learns each task from its own
    /// session brief. Nothing depends on this succeeding.
    func pushToAgent() {
        guard gateway.state.isConnected else {
            pendingPush = true          // flush once we're back
            return
        }
        pendingPush = false
        let snapshot = items
        Task {
            guard let data = try? JSONEncoder.iso.encode(snapshot),
                  let json = String(data: data, encoding: .utf8) else { return }
            await files.write(Self.todosPath, content: json)
        }
    }

    /// Collects agent updates from two independent channels:
    ///  1. each task's own session transcript (always available), and
    ///  2. the append-only JSONL log (when the gateway allows file writes).
    func pullAgentUpdates() async {
        guard gateway.state.isConnected else { return }   // stand down while offline
        guard !syncing else { return }
        guard !activeTasks.isEmpty || !runningTasks.isEmpty else { return }
        syncing = true
        defer { syncing = false }

        await pullFromTaskSessions()
        await pullFromLogFile()
    }

    // MARK: Channel 1 — task session transcripts (robust; no file API needed)

    /// How many assistant messages we've already turned into progress notes.
    private var consumedSessionMessages: [String: Int] = [:]

    /// Tasks still worth polling. A finished task (result in hand) or one
    /// blocked on the user produces nothing new — polling it forever just
    /// hammers the gateway.
    var activeTasks: [TodoItem] {
        items.filter { task in
            guard task.owner == .athena, !task.done else { return false }
            if task.status == .readyForReview, task.hasResult { return false }
            if task.status == .waitingOnUser { return false }   // resumes on answer
            return true
        }
    }

    private func pullFromTaskSessions() async {
        for task in activeTasks {
            let key = Self.sessionKey(for: task)
            guard let history = try? await gateway.chatHistory(sessionKey: key, limit: 40)
            else { continue }
            let rows = history["messages"]?.arrayValue ?? history.arrayValue ?? []

            // Assistant replies only, in order.
            let replies: [String] = rows.compactMap { row in
                let role = row["role"]?.stringValue ?? "assistant"
                guard role != "user",
                      let text = ChatStore.extractText(row),
                      !text.isEmpty else { return nil }
                return text
            }

            let already = consumedSessionMessages[task.id] ?? 0
            guard replies.count > already else { continue }
            consumedSessionMessages[task.id] = replies.count

            for reply in replies.dropFirst(already) {
                apply(reply: reply, to: task.id)
            }
        }
    }

    /// Parses PROGRESS: / QUESTION: / STATUS: lines out of a reply.
    private func apply(reply: String, to todoId: String) {
        guard let index = items.firstIndex(where: { $0.id == todoId }) else { return }
        var touched = false
        var body = reply

        // RESULT: is multi-line and runs to the end (or to the next marker).
        if let resultRange = body.range(of: "RESULT:", options: [.caseInsensitive]) {
            let after = String(body[resultRange.upperBound...])
            var resultLines: [String] = []
            var remainder: [String] = []
            var stillResult = true
            for line in after.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isMarker = ["PROGRESS:", "QUESTION:", "STATUS:"].contains {
                    trimmed.uppercased().hasPrefix($0)
                }
                if isMarker { stillResult = false }
                stillResult ? resultLines.append(String(line)) : remainder.append(String(line))
            }
            let text = resultLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, items[index].result != text {
                items[index].result = text
                items[index].resultAt = .now
                if items[index].status != .waitingOnUser {
                    items[index].status = .readyForReview
                    items[index].percent = 100
                }
                touched = true
            }
            body = String(body[..<resultRange.lowerBound]) + "\n" + remainder.joined(separator: "\n")
        }

        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let body = value(of: "PROGRESS", in: line) {
                // Optional trailing [45%]
                var text = body
                var percent: Int?
                if let match = body.range(of: #"\[(\d{1,3})%\]"#, options: .regularExpression) {
                    percent = Int(body[match].filter(\.isNumber))
                    text = body.replacingCharacters(in: match, with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
                guard text.count > 3,
                      !items[index].progress.contains(where: { $0.text == text }) else { continue }
                items[index].progress.append(ProgressNote(text: text, percent: percent))
                if let percent { items[index].percent = percent }
                if items[index].status == .open { items[index].status = .working }
                touched = true

            } else if let body = value(of: "QUESTION", in: line) {
                guard !body.isEmpty,
                      !items[index].questions.contains(where: { $0.text == body }) else { continue }
                items[index].questions.append(AgentQuestion(text: body))
                items[index].status = .waitingOnUser
                touched = true

            } else if let body = value(of: "STATUS", in: line) {
                let normalized = body.trimmingCharacters(in: .punctuationCharacters)
                    .trimmingCharacters(in: .whitespaces)
                if let status = TodoItem.Status(rawValue: normalized) {
                    items[index].status = status
                    if status == .readyForReview { items[index].percent = 100 }
                    touched = true
                }
            }
        }

        // No markers at all: keep the substance rather than dropping it.
        if !touched {
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip fragments like a stray "{" from a tool dump.
            guard clean.count > 12 else { return }

            if clean.count > 220 {
                // A long unmarked reply is almost certainly the answer.
                if items[index].result != clean {
                    items[index].result = clean
                    items[index].resultAt = .now
                    touched = true
                }
            } else {
                let line = String(clean.prefix(160))
                if !items[index].progress.contains(where: { $0.text == line }) {
                    items[index].progress.append(ProgressNote(text: line))
                    if items[index].status == .open { items[index].status = .working }
                    touched = true
                }
            }
        }

        if touched {
            items[index].updatedAt = .now
        }
    }

    private func value(of marker: String, in line: String) -> String? {
        let patterns = ["\(marker):", "**\(marker):**", "\(marker) :"]
        for pattern in patterns where line.uppercased().hasPrefix(pattern.uppercased()) {
            return String(line.dropFirst(pattern.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: Channel 2 — the JSONL log file

    /// Optional second channel. Silent when the gateway can't expose files —
    /// the session transcript above is the reliable path.
    private func pullFromLogFile() async {
        guard logFileUsable else { return }
        guard let raw = await files.read(Self.logPath) else {
            logFileUsable = false      // stop asking
            return
        }

        let lines = raw.split(separator: "\n").map(String.init)
        guard lines.count > consumedLogLines else { return }
        let fresh = lines.dropFirst(consumedLogLines)
        consumedLogLines = lines.count

        var changed = false
        for line in fresh {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(TodoLogEntry.self, from: data),
                  let index = items.firstIndex(where: { $0.id == entry.todoId })
            else { continue }

            switch entry.type {
            case "progress":
                if let text = entry.text {
                    items[index].progress.append(
                        ProgressNote(text: text, percent: entry.percent))
                    if let percent = entry.percent { items[index].percent = percent }
                    if items[index].status == .open { items[index].status = .working }
                    changed = true
                }
            case "question":
                if let text = entry.text,
                   !items[index].questions.contains(where: { $0.text == text }) {
                    items[index].questions.append(AgentQuestion(text: text))
                    items[index].status = .waitingOnUser
                    changed = true
                }
            case "status":
                if let raw = entry.status,
                   let status = TodoItem.Status(rawValue: raw) {
                    items[index].status = status
                    changed = true
                }
            default: break
            }
            items[index].updatedAt = .now
        }

        if changed {
            withAnimation(.easeInOut(duration: 0.3)) { objectWillChange.send() }
        }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
