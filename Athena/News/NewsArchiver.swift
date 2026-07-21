import Foundation

/// Persists fetched headlines so the agent can answer "what happened since we
/// last talked?" from memory instead of re-fetching everything.
///
/// Two destinations:
///  1. **Agent workspace** (`news/YYYY-MM-DD.md`) — the agent can read/grep
///     these files on demand, so summarizing costs almost no tokens.
///  2. **Local mirror** in Application Support — always written, so nothing is
///     lost if the gateway is unreachable.
///
/// Writes are append-only and de-duplicated by story link.
@MainActor
final class NewsArchiver {
    private let gateway: GatewayClient
    private lazy var files = WorkspaceFiles(gateway: gateway)
    private var archivedIDs = Set<String>()

    init(gateway: GatewayClient) {
        self.gateway = gateway
        archivedIDs = Self.loadArchivedIDs()
    }

    // `nonisolated` so background tasks can use these without hopping to the
    // main actor (the class is @MainActor, which would otherwise infect them).
    nonisolated static var localDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Athena/News", isDirectory: true)
    }

    nonisolated private static var indexURL: URL {
        localDirectory.appendingPathComponent("archived-ids.json")
    }

    nonisolated private static func loadArchivedIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: indexURL),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return ids
    }

    private func persistIDs() {
        // Keep the index bounded.
        if archivedIDs.count > 5000 { archivedIDs = Set(archivedIDs.suffix(3000)) }
        let ids = archivedIDs
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: Self.localDirectory,
                                                     withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(ids) {
                try? data.write(to: Self.indexURL)
            }
        }
    }

    /// Archives any items not already stored. Returns how many were new.
    @discardableResult
    func archive(_ items: [NewsItem]) async -> Int {
        let fresh = items.filter { !archivedIDs.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        fresh.forEach { archivedIDs.insert($0.id) }
        persistIDs()

        let day = Self.dayStamp()
        let markdown = await Self.renderMarkdown(fresh, capturedAt: .now)

        // 1. Local mirror (off-main).
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: Self.localDirectory,
                                                     withIntermediateDirectories: true)
            let file = Self.localDirectory.appendingPathComponent("\(day).md")
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(markdown.utf8))
                try? handle.close()
            } else {
                try? markdown.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        // 2. Agent workspace, so the agent can read it later.
        await writeToAgentWorkspace(day: day, appending: markdown)
        return fresh.count
    }

    /// Appends to `news/<day>.md` in the agent workspace via the shared
    /// WorkspaceFiles helper (which knows this gateway's file API shape).
    private func writeToAgentWorkspace(day: String, appending markdown: String) async {
        let path = "news/\(day).md"
        let existing = await files.read(path) ?? ""
        let combined = existing.isEmpty
            ? "# News archive — \(day)\n\n" + markdown
            : existing + markdown
        let method = await files.write(path, content: combined)
        if method == .unavailable {
            NSLog("[news] could not write archive to agent workspace — local copy kept")
        }
    }

    // MARK: Reading back from agent memory
    //
    // The UI can show everything the agent collected — including hours when
    // this Mac was asleep — by reading the same archive files it writes.

    /// Loads and parses `news/<day>.md` from the agent workspace.
    func loadArchive(daysBack: Int = 2) async -> [NewsItem] {
        var all: [NewsItem] = []
        for offset in 0...max(0, daysBack) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now)
            else { continue }
            let day = Self.dayStamp(date)
            guard let markdown = await readFile(path: "news/\(day).md") else { continue }
            let parsed = await Self.parseMarkdown(markdown, day: date)
            all.append(contentsOf: parsed)
            parsed.forEach { archivedIDs.insert($0.id) }   // don't re-archive
        }
        return all
    }

    private func readFile(path: String) async -> String? {
        if let text = await files.read(path), !text.isEmpty { return text }
        // Local mirror fallback.
        let local = Self.localDirectory.appendingPathComponent((path as NSString).lastPathComponent)
        return try? String(contentsOf: local, encoding: .utf8)
    }

    /// Parses our own archive format back into items:
    /// `- **Headline** — source.com _(Region)_ https://link`
    nonisolated static func parseMarkdown(_ markdown: String, day: Date) async -> [NewsItem] {
        await Task.detached(priority: .utility) { () -> [NewsItem] in
            var items: [NewsItem] = []
            var topic = "Archive"
            var captured = day

            for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)

                if text.hasPrefix("### ") {
                    topic = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if text.hasPrefix("## Captured ") {
                    let hhmm = String(text.dropFirst("## Captured ".count))
                        .trimmingCharacters(in: .whitespaces)
                    let parts = hhmm.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 {
                        captured = Calendar.current.date(bySettingHour: parts[0], minute: parts[1],
                                                         second: 0, of: day) ?? day
                    }
                    continue
                }
                guard text.hasPrefix("- ") else { continue }

                let body = String(text.dropFirst(2))
                // Headline between ** **
                guard let titleStart = body.range(of: "**"),
                      let titleEnd = body.range(of: "**", range: titleStart.upperBound..<body.endIndex)
                else { continue }
                let title = String(body[titleStart.upperBound..<titleEnd.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }

                let rest = String(body[titleEnd.upperBound...])
                let link = rest.split(separator: " ").first { $0.hasPrefix("http") }.map(String.init)
                var source = rest
                    .replacingOccurrences(of: "—", with: "")
                    .replacingOccurrences(of: link ?? "", with: "")
                if let placeStart = source.range(of: "_(") {
                    source = String(source[source.startIndex..<placeStart.lowerBound])
                }
                source = source.trimmingCharacters(in: .whitespaces)

                items.append(NewsItem(
                    id: link ?? "archive-\(title.hashValue)",
                    topic: topic,
                    title: title,
                    link: link.flatMap(URL.init(string:)),
                    source: source.isEmpty ? "archive" : source,
                    date: captured,
                    summary: ""))
            }
            return items
        }.value
    }

    // MARK: Rendering

    nonisolated static func dayStamp(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Compact markdown: one line per story, grouped by topic.
    nonisolated static func renderMarkdown(_ items: [NewsItem], capturedAt: Date) async -> String {
        await Task.detached(priority: .background) {
            let time = DateFormatter()
            time.dateFormat = "HH:mm"
            var out = "\n## Captured \(time.string(from: capturedAt))\n\n"
            let byTopic = Dictionary(grouping: items, by: \.topic)
            for topic in byTopic.keys.sorted() {
                out += "### \(topic)\n"
                for item in byTopic[topic] ?? [] {
                    let place = GeoTagger.place(for: item).map { " _(\($0.name))_" } ?? ""
                    let link = item.link?.absoluteString ?? ""
                    out += "- **\(item.title)** — \(item.source)\(place) \(link)\n"
                    if !item.summary.isEmpty {
                        out += "  \(item.summary.prefix(220))\n"
                    }
                }
                out += "\n"
            }
            return out
        }.value
    }

    /// Prompt that makes the agent summarize from its stored archive rather
    /// than going out to fetch again.
    static func sinceLastTalkPrompt() -> String {
        """
        Read the news archive files in your workspace under `news/` (today's file \
        is `news/\(dayStamp()).md`, yesterday's is the previous date). Using ONLY \
        what's stored there — do not fetch anything new — tell me what's happened \
        since we last talked. Group by theme, lead with anything genuinely \
        important, and keep it under 250 words.
        """
    }

    /// Cron prompt for true 24/7 collection on the gateway (works while this
    /// Mac is asleep).
    static func backgroundCollectionPrompt(topics: [NewsTopic]) -> String {
        var lines = ["Collect news for my monitored topics. Sources:"]
        for topic in topics where topic.enabled {
            lines.append("## \(topic.name)")
            lines.append(contentsOf: topic.sources.map { "- \($0)" })
        }
        lines.append("""

        Steps:
        1. Fetch each feed and keep items published since your last run.
        2. Append them to `news/<today's date>.md` in your workspace, using the \
        format: `- **Headline** — source (region) link`, grouped by topic under \
        a `## Captured HH:MM` heading. Create the file if needed.
        3. Do not message me. Reply only with HEARTBEAT_OK.
        """)
        return lines.joined(separator: "\n")
    }
}
