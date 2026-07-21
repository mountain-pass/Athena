import Foundation

struct NewsItem: Identifiable, Hashable {
    let id: String            // link (or title hash fallback)
    let topic: String
    let title: String
    let link: URL?
    let source: String        // feed host, e.g. "techcrunch.com"
    let date: Date?
    let summary: String       // plain text, HTML stripped

    var ageLabel: String {
        guard let date else { return "" }
        let mins = Int(-date.timeIntervalSinceNow / 60)
        if mins < 60 { return "\(max(1, mins))m" }
        if mins < 60 * 24 { return "\(mins / 60)h" }
        return "\(mins / (60 * 24))d"
    }
}

/// Minimal RSS 2.0 + Atom parser (XMLParser-based, no dependencies).
final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [NewsItem] = []
    private var topic = ""
    private var source = ""

    private var inItem = false
    private var currentElement = ""
    private var title = "", link = "", pubDate = "", summary = ""

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    func parse(data: Data, topic: String, sourceURL: URL) -> [NewsItem] {
        items = []
        self.topic = topic
        self.source = sourceURL.host?.replacingOccurrences(of: "www.", with: "") ?? "feed"
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let el = name.lowercased()
        if el == "item" || el == "entry" {
            inItem = true
            title = ""; link = ""; pubDate = ""; summary = ""
        }
        guard inItem else { return }
        currentElement = el
        // Atom: <link href="…"/>
        if el == "link", link.isEmpty, let href = attributes["href"] { link = href }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch currentElement {
        case "title": title += string
        case "link": link += string
        case "pubdate", "published", "updated", "dc:date": pubDate += string
        case "description", "summary", "content", "content:encoded":
            if summary.count < 2000 { summary += string }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inItem, let s = String(data: CDATABlock, encoding: .utf8) else { return }
        switch currentElement {
        case "title": title += s
        case "description", "summary", "content", "content:encoded":
            if summary.count < 2000 { summary += s }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let el = name.lowercased()
        if el == "item" || el == "entry" {
            inItem = false
            let cleanTitle = Self.stripHTML(title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return }
            let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(NewsItem(
                id: trimmedLink.isEmpty ? "\(source)-\(cleanTitle.hashValue)" : trimmedLink,
                topic: topic,
                title: cleanTitle,
                link: URL(string: trimmedLink),
                source: source,
                date: Self.parseDate(pubDate.trimmingCharacters(in: .whitespacesAndNewlines)),
                summary: Self.stripHTML(summary).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        } else if currentElement == el {
            currentElement = ""
        }
    }

    static func parseDate(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let d = rfc822.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        // RFC822 without seconds
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm Z"
        return f.date(from: s)
    }

    static func stripHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#8217;": "'",
                        "&#8216;": "'", "&#8220;": "\u{201C}", "&#8221;": "\u{201D}"]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
