import Foundation

/// A place mentioned in the news, with its position on the globe.
struct GeoPlace: Hashable {
    let name: String
    let lat: Double
    let lon: Double
}

/// A cluster of stories pinned to one place — drawn as a pulsing target on the globe.
struct GeoHotspot: Identifiable, Hashable {
    let place: GeoPlace
    let items: [NewsItem]
    var id: String { place.name }
    var intensity: Double { min(1, Double(items.count) / 6) }
}

/// Lightweight keyword → coordinates matcher. Runs locally over headlines;
/// no API, no tokens. Unmatched stories simply don't appear on the globe
/// (they're still listed in the topic columns).
enum GeoTagger {

    /// Keyword patterns → place. Order matters: cities before countries so
    /// "New York" wins over a bare "US".
    private static let table: [(keys: [String], place: GeoPlace)] = [
        // US cities / regions
        (["new york", "wall street", "nyc", "manhattan"], GeoPlace(name: "New York", lat: 40.7, lon: -74.0)),
        (["silicon valley", "san francisco", "bay area", "openai", "meta ", "google", "apple inc", "nvidia", "anthropic"],
         GeoPlace(name: "San Francisco", lat: 37.77, lon: -122.4)),
        (["washington", "white house", "pentagon", "congress", "senate", "trump", "biden", "capitol"],
         GeoPlace(name: "Washington DC", lat: 38.9, lon: -77.0)),
        (["los angeles", "hollywood", "california"], GeoPlace(name: "Los Angeles", lat: 34.05, lon: -118.2)),
        (["seattle", "microsoft", "amazon"], GeoPlace(name: "Seattle", lat: 47.6, lon: -122.3)),
        (["texas", "austin", "houston"], GeoPlace(name: "Texas", lat: 30.3, lon: -97.7)),
        (["chicago"], GeoPlace(name: "Chicago", lat: 41.9, lon: -87.6)),
        (["canada", "toronto", "ottawa", "canadian"], GeoPlace(name: "Canada", lat: 45.4, lon: -75.7)),
        (["mexico"], GeoPlace(name: "Mexico", lat: 19.4, lon: -99.1)),
        (["brazil", "brasil", "são paulo", "sao paulo"], GeoPlace(name: "Brazil", lat: -23.5, lon: -46.6)),
        (["argentina", "buenos aires"], GeoPlace(name: "Argentina", lat: -34.6, lon: -58.4)),

        // Europe
        (["london", "uk ", "britain", "british", "england", "downing street"],
         GeoPlace(name: "London", lat: 51.5, lon: -0.13)),
        (["ireland", "dublin"], GeoPlace(name: "Ireland", lat: 53.3, lon: -6.2)),
        (["france", "paris", "macron"], GeoPlace(name: "Paris", lat: 48.85, lon: 2.35)),
        (["germany", "berlin", "munich"], GeoPlace(name: "Germany", lat: 52.5, lon: 13.4)),
        (["spain", "madrid", "barcelona"], GeoPlace(name: "Spain", lat: 40.4, lon: -3.7)),
        (["italy", "rome", "milan"], GeoPlace(name: "Italy", lat: 41.9, lon: 12.5)),
        (["netherlands", "amsterdam", "dutch", "asml"], GeoPlace(name: "Netherlands", lat: 52.4, lon: 4.9)),
        (["switzerland", "zurich", "geneva", "davos"], GeoPlace(name: "Switzerland", lat: 47.4, lon: 8.5)),
        (["sweden", "stockholm", "norway", "oslo", "denmark", "copenhagen", "finland", "helsinki"],
         GeoPlace(name: "Nordics", lat: 59.3, lon: 18.1)),
        (["poland", "warsaw"], GeoPlace(name: "Poland", lat: 52.2, lon: 21.0)),
        (["ukraine", "kyiv", "kiev", "zelensky"], GeoPlace(name: "Ukraine", lat: 50.45, lon: 30.5)),
        (["russia", "moscow", "kremlin", "putin"], GeoPlace(name: "Russia", lat: 55.75, lon: 37.6)),
        (["european union", "brussels", "eu "], GeoPlace(name: "Brussels", lat: 50.85, lon: 4.35)),

        // Middle East / Africa
        (["israel", "tel aviv", "jerusalem", "gaza"], GeoPlace(name: "Israel", lat: 32.1, lon: 34.8)),
        (["iran", "tehran"], GeoPlace(name: "Iran", lat: 35.7, lon: 51.4)),
        (["saudi", "riyadh"], GeoPlace(name: "Saudi Arabia", lat: 24.7, lon: 46.7)),
        (["uae", "dubai", "abu dhabi"], GeoPlace(name: "UAE", lat: 25.2, lon: 55.3)),
        (["turkey", "istanbul", "ankara"], GeoPlace(name: "Turkey", lat: 41.0, lon: 28.98)),
        (["egypt", "cairo"], GeoPlace(name: "Egypt", lat: 30.0, lon: 31.2)),
        (["nigeria", "lagos"], GeoPlace(name: "Nigeria", lat: 6.5, lon: 3.4)),
        (["south africa", "johannesburg", "cape town"], GeoPlace(name: "South Africa", lat: -26.2, lon: 28.0)),
        (["kenya", "nairobi"], GeoPlace(name: "Kenya", lat: -1.3, lon: 36.8)),

        // Asia-Pacific
        (["china", "beijing", "shanghai", "shenzhen", "chinese", "huawei", "alibaba", "deepseek"],
         GeoPlace(name: "China", lat: 39.9, lon: 116.4)),
        (["hong kong"], GeoPlace(name: "Hong Kong", lat: 22.3, lon: 114.2)),
        (["taiwan", "taipei", "tsmc"], GeoPlace(name: "Taiwan", lat: 25.0, lon: 121.6)),
        (["japan", "tokyo", "sony", "nintendo", "toyota"], GeoPlace(name: "Tokyo", lat: 35.7, lon: 139.7)),
        (["korea", "seoul", "samsung", "sk hynix"], GeoPlace(name: "South Korea", lat: 37.6, lon: 127.0)),
        (["india", "delhi", "mumbai", "bengaluru", "bangalore"], GeoPlace(name: "India", lat: 28.6, lon: 77.2)),
        (["singapore"], GeoPlace(name: "Singapore", lat: 1.35, lon: 103.8)),
        (["indonesia", "jakarta"], GeoPlace(name: "Indonesia", lat: -6.2, lon: 106.8)),
        (["vietnam", "hanoi"], GeoPlace(name: "Vietnam", lat: 21.0, lon: 105.8)),
        (["thailand", "bangkok"], GeoPlace(name: "Thailand", lat: 13.75, lon: 100.5)),
        (["australia", "sydney", "melbourne", "canberra"], GeoPlace(name: "Australia", lat: -33.87, lon: 151.2)),
        (["new zealand", "auckland", "wellington"], GeoPlace(name: "New Zealand", lat: -36.85, lon: 174.8)),
    ]

    /// Fallback when nothing matches but the source implies a country.
    private static let sourceFallback: [(key: String, place: GeoPlace)] = [
        ("bbci.co.uk", GeoPlace(name: "London", lat: 51.5, lon: -0.13)),
        ("theartnewspaper", GeoPlace(name: "London", lat: 51.5, lon: -0.13)),
        ("cnbc.com", GeoPlace(name: "New York", lat: 40.7, lon: -74.0)),
        ("dowjones.io", GeoPlace(name: "New York", lat: 40.7, lon: -74.0)),
        ("techcrunch.com", GeoPlace(name: "San Francisco", lat: 37.77, lon: -122.4)),
        ("arstechnica.com", GeoPlace(name: "San Francisco", lat: 37.77, lon: -122.4)),
        ("hnrss.org", GeoPlace(name: "San Francisco", lat: 37.77, lon: -122.4)),
        ("venturebeat.com", GeoPlace(name: "San Francisco", lat: 37.77, lon: -122.4)),
        ("technologyreview.com", GeoPlace(name: "Boston", lat: 42.36, lon: -71.06)),
    ]

    static func place(for item: NewsItem) -> GeoPlace? {
        let haystack = (item.title + " " + item.summary).lowercased()
        for entry in table where entry.keys.contains(where: { haystack.contains($0) }) {
            return entry.place
        }
        for entry in sourceFallback where item.source.contains(entry.key) {
            return entry.place
        }
        return nil
    }

    /// Groups items into hotspots, biggest first.
    static func hotspots(from items: [NewsItem], limit: Int = 12) -> [GeoHotspot] {
        var buckets: [GeoPlace: [NewsItem]] = [:]
        for item in items {
            guard let place = place(for: item) else { continue }
            buckets[place, default: []].append(item)
        }
        return buckets
            .map { GeoHotspot(place: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
            .prefix(limit)
            .map { $0 }
    }
}
