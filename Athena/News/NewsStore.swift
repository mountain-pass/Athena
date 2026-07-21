import Foundation
import Combine

struct NewsTopic: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    var enabled: Bool
    /// Free RSS/API sources the agent should pull for this topic.
    var sources: [String]
}

/// Configures what news the agent monitors and materializes it as a daily
/// cron job on the gateway. The agent fetches the RSS/APIs (or browses the
/// web), summarizes against your topics, and posts the brief into the main
/// chat session every morning.
@MainActor
final class NewsStore: ObservableObject {
    @Published var topics: [NewsTopic] {
        didSet { persist() }
    }
    @Published var briefHour = 7 { didSet { persist() } }
    @Published var allowBrowsing = true { didSet { persist() } }
    @Published private(set) var syncStatus: String?

    // Live feed items for the dashboard (fetched natively from RSS — fast,
    // free, no LLM tokens; the agent is used for briefs/summaries).
    @Published private(set) var items: [NewsItem] = []
    @Published private(set) var fetching = false
    @Published private(set) var lastFetched: Date?

    static let cronJobName = "athena-daily-news-brief"

    private let gateway: GatewayClient

    static let defaultTopics: [NewsTopic] = [
        NewsTopic(name: "Finance", enabled: true, sources: [
            "https://feeds.content.dowjones.io/public/rss/mw_topstories",   // MarketWatch
            "https://www.cnbc.com/id/100003114/device/rss/rss.html",        // CNBC Top News
            "https://feeds.bbci.co.uk/news/business/rss.xml",
        ]),
        NewsTopic(name: "Technology", enabled: true, sources: [
            "https://hnrss.org/frontpage",                                  // Hacker News
            "https://feeds.arstechnica.com/arstechnica/index",
            "https://techcrunch.com/feed/",
        ]),
        NewsTopic(name: "AI", enabled: true, sources: [
            "https://hnrss.org/newest?q=AI",
            "https://www.technologyreview.com/feed/",
            "https://venturebeat.com/category/ai/feed/",
        ]),
        NewsTopic(name: "Art & Culture", enabled: false, sources: [
            "https://www.theartnewspaper.com/rss.xml",
            "https://hyperallergic.com/feed/",
            "https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml",
        ]),
    ]

    init(gateway: GatewayClient) {
        self.gateway = gateway
        if let data = UserDefaults.standard.data(forKey: "news.topics"),
           let saved = try? JSONDecoder().decode([NewsTopic].self, from: data) {
            topics = saved
        } else {
            topics = Self.defaultTopics
        }
        briefHour = UserDefaults.standard.object(forKey: "news.briefHour") as? Int ?? 7
        allowBrowsing = UserDefaults.standard.object(forKey: "news.allowBrowsing") as? Bool ?? true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(topics) {
            UserDefaults.standard.set(data, forKey: "news.topics")
        }
        UserDefaults.standard.set(briefHour, forKey: "news.briefHour")
        UserDefaults.standard.set(allowBrowsing, forKey: "news.allowBrowsing")
    }

    // MARK: Topic CRUD

    func addTopic(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !topics.contains(where: { $0.name == trimmed }) else { return }
        topics.append(NewsTopic(name: trimmed, enabled: true, sources: []))
    }

    func deleteTopic(_ topic: NewsTopic) {
        topics.removeAll { $0.id == topic.id }
    }

    // MARK: Live feed fetching

    var enabledTopics: [NewsTopic] { topics.filter(\.enabled) }

    func itemsFor(_ topic: String) -> [NewsItem] {
        items.filter { $0.topic == topic }
    }

    func fetchLatest(force: Bool = false) {
        if fetching { return }
        if !force, let last = lastFetched, Date().timeIntervalSince(last) < 600 { return }
        fetching = true
        let targets = enabledTopics.flatMap { topic in
            topic.sources.compactMap { src in URL(string: src).map { (topic.name, $0) } }
        }
        Task {
            var collected: [NewsItem] = []
            await withTaskGroup(of: [NewsItem].self) { group in
                for (topicName, url) in targets {
                    group.addTask {
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 12
                        req.setValue("Athena/0.1 (RSS reader)", forHTTPHeaderField: "User-Agent")
                        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
                        return RSSParser().parse(data: data, topic: topicName, sourceURL: url)
                    }
                }
                for await batch in group { collected.append(contentsOf: batch) }
            }
            // Dedupe by normalized title, newest first, cap per topic.
            var seen = Set<String>()
            let sorted = collected.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            var deduped: [NewsItem] = []
            var perTopic: [String: Int] = [:]
            for item in sorted {
                let key = item.title.lowercased().prefix(60)
                guard !seen.contains(String(key)) else { continue }
                guard (perTopic[item.topic] ?? 0) < 25 else { continue }
                seen.insert(String(key))
                perTopic[item.topic, default: 0] += 1
                deduped.append(item)
            }
            self.items = deduped
            self.lastFetched = .now
            self.fetching = false
        }
    }

    // MARK: Gateway sync

    /// The prompt the cron job runs every morning on the gateway.
    var briefPrompt: String {
        let active = topics.filter(\.enabled)
        var lines: [String] = [
            "Generate my daily news brief. Topics and sources:",
        ]
        for topic in active {
            lines.append("## \(topic.name)")
            lines.append(contentsOf: topic.sources.map { "- \($0)" })
        }
        lines.append("""

        Instructions:
        1. Fetch each RSS/API source above and collect items from the last 24 hours.
        2. Pick the 3–5 most important stories per topic; deduplicate across sources.
        3. For each story: one-line headline, two-sentence why-it-matters, link.
        4. Open with a 3-sentence overall summary. Keep the whole brief under 600 words.
        \(allowBrowsing ? "5. If a feed fails, you may use web search/browsing to fill the topic." : "5. Do not browse the web; RSS only.")
        """)
        return lines.joined(separator: "\n")
    }

    /// Creates/updates the daily cron job on the gateway.
    func syncToGateway() {
        Task {
            syncStatus = "Syncing…"
            do {
                let jobs = try await gateway.cronList()
                let existing = jobs.first { $0["name"]?.stringValue == Self.cronJobName }
                let schedule = "0 \(briefHour) * * *"
                if let existing, let id = existing["id"]?.stringValue {
                    _ = try await gateway.cronUpdate(id: id, patch: .from([
                        "schedule": ["kind": "cron", "expr": schedule],
                        "payload": ["kind": "agentTurn", "message": briefPrompt],
                        "enabled": topics.contains(where: \.enabled),
                    ]))
                } else {
                    _ = try await gateway.cronAdd(name: Self.cronJobName,
                                                  schedule: schedule,
                                                  prompt: briefPrompt)
                }
                syncStatus = "✓ Daily brief scheduled for \(String(format: "%02d:00", briefHour)) on the gateway"
            } catch {
                syncStatus = "✗ \(error.localizedDescription)"
            }
        }
    }

    /// Ask for a brief right now (runs through normal chat).
    func runNow(chat: ChatStore) {
        chat.send(text: briefPrompt, viaVoice: false)
    }
}
