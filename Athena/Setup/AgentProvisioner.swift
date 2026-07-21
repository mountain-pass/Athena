import Foundation

/// Teaches the OpenClaw agent its role in the Athena system.
///
/// Athena is only a display layer — the agent is the product. Rather than the
/// app compensating with ad-hoc prompt hacks on every message, we write a
/// persistent operating manual into the agent's workspace and provision the
/// scheduled jobs that back it. The agent then knows:
///
///   • what Athena is and how its answers get rendered / spoken
///   • the `[voice]` convention and how to answer speakable turns
///   • where news archives live, their format, and to read them before fetching
///   • which cron jobs exist and what they're for
///
/// Managed content is fenced with markers so we never clobber anything the
/// user wrote by hand.
@MainActor
final class AgentProvisioner: ObservableObject {

    /// Bump when the operating manual's contract changes — a mismatch triggers
    /// a re-provision on the next handshake.
    static let contractVersion = 5   // v5: session-based todo protocol
    /// Stored locally, per gateway URL.
    static var manifestKey: String {
        let url = UserDefaults.standard.string(forKey: "gateway.url") ?? "default"
        return "agent.manifest.\(url)"
    }

    enum HandshakeResult: Equatable {
        case alreadyProvisioned(version: Int)
        case provisioned(reason: String)
        case failed(String)
    }

    @Published private(set) var log: [String] = []
    @Published private(set) var running = false
    @Published private(set) var lastResult: String?
    @Published private(set) var handshake: HandshakeResult?

    private let gateway: GatewayClient
    private let files: WorkspaceFiles
    private let beginMarker = "<!-- ATHENA:BEGIN — managed by the Athena macOS app -->"
    private let endMarker = "<!-- ATHENA:END -->"

    init(gateway: GatewayClient) {
        self.gateway = gateway
        self.files = WorkspaceFiles(gateway: gateway)
    }

    // MARK: Handshake — runs once per launch, not per message

    /// Asks the agent whether it already knows the Athena contract.
    /// Only provisions when the manifest is missing or out of date, so normal
    /// messaging stays lean (no per-message instructions).
    @discardableResult
    func verifyOrProvision(news: NewsStore, todos: TodoStore? = nil) async -> HandshakeResult {
        // The manifest lives locally: this gateway only permits bootstrap
        // files in its workspace, so there's nowhere remote to keep it.
        // Keyed per gateway so switching machines re-provisions correctly.
        let raw = UserDefaults.standard.string(forKey: Self.manifestKey)

        if let raw,
           let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(Manifest.self, from: data) {

            if parsed.contractVersion == Self.contractVersion,
               parsed.topicsFingerprint == Self.fingerprint(for: news) {
                note("✓ Agent already knows the Athena contract (v\(parsed.contractVersion))")
                let result = HandshakeResult.alreadyProvisioned(version: parsed.contractVersion)
                handshake = result
                return result
            }

            let reason = parsed.contractVersion != Self.contractVersion
                ? "contract v\(parsed.contractVersion) → v\(Self.contractVersion)"
                : "monitored topics changed"
            note("↻ Re-provisioning: \(reason)")
            await provision(news: news, todos: todos)
            let result = HandshakeResult.provisioned(reason: reason)
            handshake = result
            return result
        }

        note("＋ Agent has no Athena contract — provisioning now")
        await provision(news: news, todos: todos)
        let result = HandshakeResult.provisioned(reason: "first run")
        handshake = result
        return result
    }

    private struct Manifest: Codable {
        var contractVersion: Int
        var topicsFingerprint: String
        var provisionedAt: String
        var client: String
    }

    private static func fingerprint(for news: NewsStore) -> String {
        let payload = news.topics
            .filter(\.enabled)
            .map { "\($0.name):\($0.sources.sorted().joined(separator: ","))" }
            .sorted()
            .joined(separator: "|")
            + "|brief=\(news.briefHour)"
        return String(payload.hashValue, radix: 16)
    }

    private func writeManifest(news: NewsStore) async {
        let manifest = Manifest(
            contractVersion: Self.contractVersion,
            topicsFingerprint: Self.fingerprint(for: news),
            provisionedAt: ISO8601DateFormatter().string(from: .now),
            client: "athena-macos")
        guard let data = try? JSONEncoder().encode(manifest),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: Self.manifestKey)
        note("  ✓ recorded contract v\(Self.contractVersion)")
    }

    // MARK: Entry point

    /// Writes the operating manual, heartbeat checklist, seeds the shared todo
    /// files, and schedules jobs.
    func provision(news: NewsStore, todos: TodoStore? = nil) async {
        running = true
        log = []
        defer { running = false }

        if let id = await files.resolveAgentId() { note("agent: \(id)") }

        await upsertFile(path: "AGENTS.md", managed: operatingManual(news: news),
                         label: "operating manual")
        await upsertFile(path: "HEARTBEAT.md", managed: heartbeatChecklist(),
                         label: "heartbeat checklist")
        await seedTodoFiles(todos: todos)
        await ensureJobs(news: news)
        await writeManifest(news: news)

        lastResult = "✓ Agent provisioned — it now knows its role, the archive format, and the voice contract."
        note(lastResult!)
    }

    private func note(_ line: String) { log.append(line) }

    // MARK: File writing (non-destructive)

    private func upsertFile(path: String, managed: String, label: String) async {
        let existing = await files.read(path) ?? ""

        let block = "\(beginMarker)\n\(managed)\n\(endMarker)"
        let updated: String

        if let start = existing.range(of: beginMarker),
           let end = existing.range(of: endMarker) {
            // Replace just our section, preserving the user's own content.
            updated = existing.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
            note("↻ updating managed section in \(path)")
        } else if existing.isEmpty {
            updated = block + "\n"
            note("＋ creating \(path)")
        } else {
            updated = existing + "\n\n" + block + "\n"
            note("＋ appending managed section to \(path)")
        }

        let method = await files.write(path, content: updated)
        if method == .unavailable {
            note("  ✗ \(path): could not write (no supported file API)")
        } else {
            note("  ✓ wrote \(label) — via \(method.rawValue)")
        }
    }

    // MARK: Todo files
    //
    // Seeded during provisioning so the agent finds both files on startup and
    // knows the protocol is live — not just described in the manual.

    private func seedTodoFiles(todos: TodoStore?) async {
        // This gateway restricts agents.files.* to bootstrap files, so we no
        // longer try to plant todos.json / todo-log.jsonl. The app holds the
        // canonical list and briefs the agent per task in its own session.
        let count = todos?.items.filter { $0.owner == .athena && !$0.done }.count ?? 0
        note("✓ todo protocol documented (\(count) task(s) currently delegated)")
    }

    // MARK: Jobs

    private func ensureJobs(news: NewsStore) async {
        do {
            let jobs = try await gateway.cronList()
            let names = Set(jobs.compactMap { $0["name"]?.stringValue })

            if !names.contains(NewsStore.collectionJobName) {
                _ = try await gateway.cronAdd(
                    name: NewsStore.collectionJobName,
                    schedule: "0 * * * *",
                    prompt: NewsArchiver.backgroundCollectionPrompt(topics: news.topics))
                note("＋ hourly news collector scheduled")
            } else {
                note("✓ hourly news collector already scheduled")
            }

            if !names.contains(NewsStore.cronJobName) {
                _ = try await gateway.cronAdd(
                    name: NewsStore.cronJobName,
                    schedule: "0 \(news.briefHour) * * *",
                    prompt: news.briefPrompt)
                note("＋ daily brief scheduled for \(String(format: "%02d:00", news.briefHour))")
            } else {
                note("✓ daily brief already scheduled")
            }
        } catch {
            note("✗ scheduling failed: \(error.localizedDescription)")
        }
    }

    // MARK: Documents

    func operatingManual(news: NewsStore) -> String {
        let topics = news.topics.filter(\.enabled)
        var sourceLines = ""
        for topic in topics {
            sourceLines += "\n### \(topic.name)\n"
            sourceLines += topic.sources.map { "- \($0)" }.joined(separator: "\n")
            sourceLines += "\n"
        }

        return """
        # Working with Athena

        You are the agent behind **Athena**, a native macOS app. Athena is only a
        display layer: it renders your replies, speaks them aloud when asked, and
        shows your heartbeat, tools and memory activity. All real work — memory,
        tools, scheduling, news collection — is yours.

        ## How replies are consumed

        Athena renders markdown, so normal formatting is fine for typed chat.
        Two exceptions matter:

        1. **Voice turns.** When a message begins with `[voice]` (or an explicit
           voice note), the user *spoke* it and will *hear* your reply through
           text-to-speech. Reply in plain speakable prose:
           - no markdown, headings, bullet lists, tables or code fences
           - no emoji, no raw URLs (say "I'll put the link in the chat" instead)
           - short sentences, contractions, conversational register
           - lead with the answer; keep it under ~120 words unless asked for more
        2. **Typed turns.** Markdown is welcome — lists and bold help scanning.

        ### Emotion tags (voice turns only)

        When the user's TTS engine supports it, you may colour your delivery with
        inline tags at the start of a sentence:

        `(happy) (excited) (sad) (angry) (whispers) (laughs) (calm) (surprised) (serious)`

        Example: `(calm) Nothing needs your attention. (excited) But the thing you
        asked about last week just shipped.`

        Use them sparingly and only where they genuinely fit — one or two per
        reply at most. Anything in parentheses that isn't a known tag is treated
        as freeform direction, e.g. `(speaking quickly)`. Never use tags on typed
        turns; they'd just be read as literal text.

        ## News monitoring — your standing job

        The user tracks these topics. Athena also fetches them client-side, but
        **you own the archive**:
        \(sourceLines)
        ### Archive format

        Store everything under `news/` in your workspace, one file per day:

        ```
        news/YYYY-MM-DD.md
        ```

        Append entries under a timestamped heading, grouped by topic:

        ```markdown
        ## Captured 14:00

        ### Technology
        - **Headline text** — source.com _(San Francisco)_ https://link
          Optional one-line summary.
        ```

        Never rewrite history — append only, and skip stories already present.

        **The format is a contract, not a suggestion.** The Athena UI reads these
        same files back over the gateway (`agents.files.get`) and parses them to
        display what you collected while the user's Mac was asleep. Keep exactly:

        - `## Captured HH:MM` for each batch
        - `### Topic` for each group
        - `- **Headline** — source _(Region)_ https://link` for each story

        If you drift from this shape, the user's dashboard silently loses stories.

        ### Answering "what's happened?"

        When the user asks what happened, what's new, or for a catch-up:

        1. **Read `news/` first.** Today's file, then previous days as needed.
        2. Summarize from what's stored. Do **not** re-fetch feeds — that's slow
           and wastes tokens; the archive exists precisely so you don't have to.
        3. Only fetch live if the archive is empty or the user explicitly asks
           for the very latest.
        4. Lead with what actually matters, group by theme, name the source.
           If the user asked by voice, follow the voice rules above.

        ## Shared todo list

        The user and you share a task list. **Athena keeps the canonical list
        in the app** — you don't need to read or write it. Each task you're
        given arrives as a `[todo-assign]` message in its own session, and you
        report back in that same session using the marker lines below.

        (If you also keep your own notes on disk with your file tools, that's
        fine and useful for your memory — but Athena doesn't depend on it.)

        ### The task session — and the RESULT block

        Each delegated task also gets its own session (`athena-todo-<id>`).
        When Athena messages you there, reply with marker lines it parses:

        ```
        PROGRESS: Pulled the last 4 quarters of filings [40%]
        QUESTION: Do you want this in AUD or USD?
        STATUS: working
        RESULT:
        <the actual answer — numbers, summary, draft, whatever was asked for>
        ```

        **The RESULT block is the point of the task.** Progress notes describe
        what you did; RESULT is what the user receives. A task that ends with
        only progress notes has failed the user even if the work was done.
        It runs to the end of the message, may span many lines, and may use
        markdown, tables or code blocks — Athena renders it properly.

        Finish with `STATUS: readyForReview`. Never mark a task complete.

        - **progress** — what you did, in one plain sentence. Include `percent`
          when you can estimate it. Log as you go, not just at the end.
        - **question** — ask when genuinely blocked. Athena surfaces it to the
          user and sends their answer back to you. One question per entry.
        - **status** — `working` when you start, `waitingOnUser` when blocked,
          `readyForReview` when you believe it's finished.

        ### Rules

        1. **Never mark a task complete.** Only the user decides that. Use
           `readyForReview` and stop.
        2. Append only — never rewrite or truncate the log or `todos.json`.
        3. When Athena sends you a `[todo-assign]` or `[todo-answer]` message,
           start (or resume) that task and log progress.
        4. If a task is impossible or wrong, log a `question` explaining why
           rather than silently giving up.
        5. Keep entries short. The user reads these in a small panel.

        ## Scheduled jobs you run

        | Job | Cadence | Purpose |
        |---|---|---|
        | `\(NewsStore.collectionJobName)` | hourly | Fetch feeds, append to `news/<date>.md`, stay silent (`HEARTBEAT_OK`) |
        | `\(NewsStore.cronJobName)` | daily \(String(format: "%02d:00", news.briefHour)) | Compose the morning brief from the archive |

        Collection jobs should never message the user — they exist so that the
        archive is warm whenever the user asks something.

        ## Contract version

        Athena records which version of this contract you were set up with and
        checks it once at connection time. If it matches, the app sends no setup
        instructions at all and messages stay lean.

        ## Tone

        You're a personal assistant, not a search engine. Be direct, skip
        preamble, say when you don't know, and don't pad answers with caveats.
        """
    }

    func heartbeatChecklist() -> String {
        """
        # Heartbeat checklist

        tasks:

        - name: news-sweep
          interval: 1h
          prompt: "Fetch the monitored news feeds and append anything new to news/<today>.md in the archive format. Do not message the user; reply HEARTBEAT_OK."

        Notes:
        - Check `athena/todos.json` for tasks assigned to you (`owner: athena`,
          `done: false`). Make progress on one if you can, and log it to
          `athena/todo-log.jsonl`. Never mark tasks complete yourself.
        - Keep the news archive current so 'what happened since we last talked?'
          can be answered from memory instead of a live fetch.
        - Only surface something proactively if it's genuinely urgent for the
          user's tracked topics; otherwise reply HEARTBEAT_OK.
        """
    }
}
