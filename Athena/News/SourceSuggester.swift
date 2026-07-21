import Foundation

/// Suggests free RSS/Atom feeds for a topic.
///
/// Two tiers:
///  1. **Curated catalog** — instant, offline, covers common topics.
///  2. **Ask the agent** — for anything niche, OpenClaw is asked (in a hidden
///     side session, never the main chat) to return feed suggestions as JSON.
@MainActor
final class SourceSuggester: ObservableObject {

    struct Suggestion: Identifiable, Hashable {
        let name: String
        let url: String
        var id: String { url }
    }

    @Published private(set) var agentSuggestions: [String: [Suggestion]] = [:]
    @Published private(set) var loadingTopics: Set<String> = []
    @Published var lastError: String?

    /// Hidden session so suggestion traffic never appears in the chat tab.
    static let sessionKey = "athena-config"

    private let gateway: GatewayClient

    init(gateway: GatewayClient) { self.gateway = gateway }

    // MARK: Curated catalog (instant)

    private static let catalog: [(keywords: [String], feeds: [Suggestion])] = [
        (["crypto", "bitcoin", "blockchain", "web3"], [
            .init(name: "CoinDesk", url: "https://www.coindesk.com/arc/outboundfeeds/rss/"),
            .init(name: "Cointelegraph", url: "https://cointelegraph.com/rss"),
            .init(name: "Decrypt", url: "https://decrypt.co/feed"),
        ]),
        (["gaming", "games", "video game"], [
            .init(name: "IGN", url: "https://feeds.ign.com/ign/all"),
            .init(name: "Polygon", url: "https://www.polygon.com/rss/index.xml"),
            .init(name: "Rock Paper Shotgun", url: "https://www.rockpapershotgun.com/feed"),
        ]),
        (["space", "astronomy", "nasa"], [
            .init(name: "NASA News", url: "https://www.nasa.gov/news-release/feed/"),
            .init(name: "Space.com", url: "https://www.space.com/feeds/all"),
            .init(name: "Ars Technica Space", url: "https://feeds.arstechnica.com/arstechnica/space"),
        ]),
        (["science", "research"], [
            .init(name: "Nature News", url: "https://www.nature.com/nature.rss"),
            .init(name: "Science Daily", url: "https://www.sciencedaily.com/rss/all.xml"),
            .init(name: "Quanta Magazine", url: "https://www.quantamagazine.org/feed/"),
        ]),
        (["sport", "sports", "football", "soccer", "nba", "nfl"], [
            .init(name: "BBC Sport", url: "https://feeds.bbci.co.uk/sport/rss.xml"),
            .init(name: "ESPN", url: "https://www.espn.com/espn/rss/news"),
        ]),
        (["world", "global", "international", "geopolitics"], [
            .init(name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml"),
            .init(name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml"),
            .init(name: "The Guardian World", url: "https://www.theguardian.com/world/rss"),
        ]),
        (["politics", "election", "government"], [
            .init(name: "Politico", url: "https://www.politico.com/rss/politicopicks.xml"),
            .init(name: "BBC Politics", url: "https://feeds.bbci.co.uk/news/politics/rss.xml"),
        ]),
        (["business", "economy", "markets"], [
            .init(name: "BBC Business", url: "https://feeds.bbci.co.uk/news/business/rss.xml"),
            .init(name: "CNBC", url: "https://www.cnbc.com/id/100003114/device/rss/rss.html"),
            .init(name: "The Economist", url: "https://www.economist.com/finance-and-economics/rss.xml"),
        ]),
        (["music", "bands", "albums"], [
            .init(name: "Pitchfork", url: "https://pitchfork.com/feed/feed-news/rss"),
            .init(name: "Rolling Stone", url: "https://www.rollingstone.com/music/feed/"),
        ]),
        (["movies", "film", "cinema", "tv", "streaming"], [
            .init(name: "Variety", url: "https://variety.com/feed/"),
            .init(name: "The Verge Entertainment", url: "https://www.theverge.com/rss/entertainment/index.xml"),
        ]),
        (["health", "medicine", "fitness"], [
            .init(name: "BBC Health", url: "https://feeds.bbci.co.uk/news/health/rss.xml"),
            .init(name: "STAT News", url: "https://www.statnews.com/feed/"),
        ]),
        (["australia", "aussie", "sydney", "melbourne"], [
            .init(name: "ABC News AU", url: "https://www.abc.net.au/news/feed/51120/rss.xml"),
            .init(name: "The Age", url: "https://www.theage.com.au/rss/feed.xml"),
        ]),
    ]

    /// Instant suggestions from the built-in catalog.
    nonisolated static func builtIn(for topic: String) -> [Suggestion] {
        let key = topic.lowercased()
        var out: [Suggestion] = []
        for entry in catalog where entry.keywords.contains(where: { key.contains($0) }) {
            out.append(contentsOf: entry.feeds)
        }
        return out
    }

    /// Everything we currently have for a topic (catalog + agent), minus
    /// feeds already added.
    func suggestions(for topic: NewsTopic) -> [Suggestion] {
        var seen = Set(topic.sources)
        var out: [Suggestion] = []
        for s in Self.builtIn(for: topic.name) + (agentSuggestions[topic.name] ?? []) {
            guard !seen.contains(s.url) else { continue }
            seen.insert(s.url)
            out.append(s)
        }
        return out
    }

    // MARK: Ask the agent

    /// Asks OpenClaw for feed suggestions in a hidden session, parses the JSON
    /// reply, and publishes the results. Non-blocking; UI shows a spinner.
    func askAgent(for topicName: String) {
        guard !loadingTopics.contains(topicName) else { return }
        loadingTopics.insert(topicName)
        lastError = nil

        let prompt = """
        Suggest up to 6 free, working RSS or Atom feeds for news about \
        "\(topicName)". Prefer major reputable outlets with reliable feeds. \
        Reply with ONLY a JSON array, no prose, in exactly this form:
        [{"name":"Outlet Name","url":"https://example.com/feed.xml"}]
        """

        Task {
            defer { loadingTopics.remove(topicName) }
            do {
                _ = try await gateway.chatSend(prompt, sessionKey: Self.sessionKey)

                // Poll the hidden session's history for the JSON reply.
                for _ in 0..<20 {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let history = try? await gateway.chatHistory(
                        sessionKey: Self.sessionKey, limit: 10) else { continue }
                    let rows = history["messages"]?.arrayValue ?? history.arrayValue ?? []
                    for row in rows.reversed() {
                        let role = row["role"]?.stringValue ?? "assistant"
                        guard role != "user",
                              let text = ChatStore.extractText(row),
                              let parsed = Self.parseSuggestions(text),
                              !parsed.isEmpty else { continue }
                        agentSuggestions[topicName, default: []] = parsed
                        return
                    }
                }
                lastError = "The agent didn't return suggestions in time — try again."
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Extracts the first JSON array from a reply (tolerates prose around it).
    nonisolated static func parseSuggestions(_ text: String) -> [Suggestion]? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end else { return nil }
        let json = String(text[start...end])
        struct Row: Decodable { let name: String; let url: String }
        guard let data = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows
            .filter { $0.url.hasPrefix("http") }
            .map { Suggestion(name: $0.name, url: $0.url) }
    }
}
