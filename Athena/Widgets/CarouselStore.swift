import Foundation
import SwiftUI

struct CarouselCard: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case pinned, topic, custom }
    var id = UUID()
    var title: String
    var subtitle: String
    var detail: String
    var link: String?
    var accent: String          // "amber" | "green" | "blue" | "red"
    var source: Source = .custom
    var createdAt: Date = .now

    var color: Color {
        switch accent {
        case "green": Theme.green
        case "blue": Theme.blue
        case "red": Theme.red
        default: Theme.amber
        }
    }
}

/// Bottom carousel: cards the user pins — stories worth keeping in view,
/// topics to auto-surface, or notes they add themselves.
@MainActor
final class CarouselStore: ObservableObject {
    @Published var cards: [CarouselCard] = [] { didSet { persist() } }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "widgets.carousel.enabled") }
    }
    /// Topics whose top story is auto-pinned as a card.
    @Published var autoTopics: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(autoTopics), forKey: "widgets.carousel.topics")
        }
    }

    init() {
        enabled = UserDefaults.standard.object(forKey: "widgets.carousel.enabled") as? Bool ?? false
        autoTopics = Set(UserDefaults.standard.stringArray(forKey: "widgets.carousel.topics") ?? [])
        if let data = UserDefaults.standard.data(forKey: "widgets.carousel.cards"),
           let saved = try? JSONDecoder().decode([CarouselCard].self, from: data) {
            cards = saved
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(data, forKey: "widgets.carousel.cards")
        }
    }

    func pin(_ item: NewsItem) {
        guard !cards.contains(where: { $0.link == item.link?.absoluteString }) else { return }
        cards.insert(CarouselCard(
            title: item.title,
            subtitle: "\(item.topic) · \(item.source)",
            detail: item.summary,
            link: item.link?.absoluteString,
            accent: "amber",
            source: .pinned), at: 0)
    }

    func addCustom(title: String, detail: String, accent: String = "blue") {
        cards.insert(CarouselCard(title: title, subtitle: "Note", detail: detail,
                                  link: nil, accent: accent, source: .custom), at: 0)
    }

    func remove(_ card: CarouselCard) {
        cards.removeAll { $0.id == card.id }
    }

    /// Refreshes auto-topic cards from the latest fetched stories.
    func syncAutoTopics(from items: [NewsItem]) {
        guard !autoTopics.isEmpty else {
            cards.removeAll { $0.source == .topic }
            return
        }
        var updated = cards.filter { $0.source != .topic }
        for topic in autoTopics.sorted() {
            guard let top = items.first(where: { $0.topic == topic }) else { continue }
            updated.append(CarouselCard(
                title: top.title,
                subtitle: "\(topic) · top story",
                detail: top.summary,
                link: top.link?.absoluteString,
                accent: "green",
                source: .topic))
        }
        if updated != cards { cards = updated }
    }
}
