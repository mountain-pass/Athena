import Foundation
import SwiftUI

struct StockQuote: Identifiable, Equatable {
    let symbol: String
    var displayName: String
    var price: Double
    var change: Double
    var changePercent: Double
    var currency: String
    var marketState: String      // REGULAR / CLOSED / PRE / POST
    var id: String { symbol }

    var isUp: Bool { change >= 0 }
    var priceLabel: String {
        String(format: price >= 1000 ? "%.0f" : "%.2f", price)
    }
    var changeLabel: String {
        String(format: "%@%.2f%%", isUp ? "+" : "", changePercent)
    }
}

/// Live quotes from Yahoo Finance's public chart endpoint — free, no API key.
/// Exchange suffixes cover every market the user asked for:
///   US none · London .L · Australia .AX · Tokyo .T · Hong Kong .HK
///   Frankfurt .DE · Paris .PA · Amsterdam .AS · Shanghai .SS · Shenzhen .SZ
@MainActor
final class StockStore: ObservableObject {
    @Published var symbols: [String] {
        didSet { persist() }
    }
    @Published private(set) var quotes: [StockQuote] = []
    @Published private(set) var refreshing = false
    @Published private(set) var lastUpdate: Date?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "widgets.stocks.enabled")
            if enabled { refresh(force: true); startTimer() } else { stopTimer() }
        }
    }

    private var timer: Timer?
    private let refreshMinutes: Double = 7

    /// Popular starting points, grouped by market — used by the settings picker.
    static let presets: [(market: String, tickers: [(String, String)])] = [
        ("US", [("AAPL", "Apple"), ("MSFT", "Microsoft"), ("NVDA", "NVIDIA"),
                ("GOOGL", "Alphabet"), ("AMZN", "Amazon"), ("TSLA", "Tesla"),
                ("^GSPC", "S&P 500"), ("^IXIC", "Nasdaq")]),
        ("Australia", [("BHP.AX", "BHP"), ("CBA.AX", "CommBank"), ("CSL.AX", "CSL"),
                       ("WES.AX", "Wesfarmers"), ("^AXJO", "ASX 200")]),
        ("UK", [("HSBA.L", "HSBC"), ("SHEL.L", "Shell"), ("AZN.L", "AstraZeneca"),
                ("^FTSE", "FTSE 100")]),
        ("Europe", [("SAP.DE", "SAP"), ("ASML.AS", "ASML"), ("MC.PA", "LVMH"),
                    ("^GDAXI", "DAX")]),
        ("Asia", [("7203.T", "Toyota"), ("9984.T", "SoftBank"), ("0700.HK", "Tencent"),
                  ("9988.HK", "Alibaba"), ("^N225", "Nikkei 225"), ("^HSI", "Hang Seng")]),
        ("Crypto & FX", [("BTC-USD", "Bitcoin"), ("ETH-USD", "Ethereum"),
                         ("AUDUSD=X", "AUD/USD"), ("GC=F", "Gold")]),
    ]

    init() {
        symbols = UserDefaults.standard.stringArray(forKey: "widgets.stocks.symbols")
            ?? ["^GSPC", "^IXIC", "AAPL", "NVDA", "BTC-USD", "^AXJO"]
        enabled = UserDefaults.standard.object(forKey: "widgets.stocks.enabled") as? Bool ?? false
        if enabled { startTimer() }
    }

    private func persist() {
        UserDefaults.standard.set(symbols, forKey: "widgets.stocks.symbols")
    }

    func add(_ raw: String) {
        let symbol = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty, !symbols.contains(symbol) else { return }
        symbols.append(symbol)
        refresh(force: true)
    }

    func remove(_ symbol: String) {
        symbols.removeAll { $0 == symbol }
        quotes.removeAll { $0.symbol == symbol }
    }

    // MARK: Refresh

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: refreshMinutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    func refresh(force: Bool = false) {
        guard enabled || force, !refreshing, !symbols.isEmpty else { return }
        if !force, let last = lastUpdate, Date().timeIntervalSince(last) < 300 { return }
        refreshing = true
        let wanted = symbols

        Task {
            // All fetching + parsing off the main thread.
            let fetched = await Self.fetchQuotes(for: wanted)
            withAnimation(.easeInOut(duration: 0.3)) {
                // Preserve the user's ordering.
                self.quotes = wanted.compactMap { symbol in
                    fetched.first { $0.symbol == symbol }
                }
            }
            self.lastUpdate = .now
            self.refreshing = false
        }
    }

    nonisolated private static func fetchQuotes(for symbols: [String]) async -> [StockQuote] {
        await Task.detached(priority: .utility) { () -> [StockQuote] in
            await withTaskGroup(of: StockQuote?.self) { group in
                for symbol in symbols {
                    group.addTask { await fetchOne(symbol) }
                }
                var out: [StockQuote] = []
                for await quote in group { if let quote { out.append(quote) } }
                return out
            }
        }.value
    }

    /// Yahoo's chart endpoint returns the meta block we need and doesn't
    /// require a key or cookie (unlike /v7/finance/quote).
    nonisolated private static func fetchOne(_ symbol: String) async -> StockQuote? {
        let encoded = symbol.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string:
            "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=5m")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Yahoo rejects requests without a browser-ish UA.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                         forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any] else { return nil }

        let price = (meta["regularMarketPrice"] as? Double)
            ?? (meta["previousClose"] as? Double) ?? 0
        let previous = (meta["chartPreviousClose"] as? Double)
            ?? (meta["previousClose"] as? Double) ?? price
        let change = price - previous
        let percent = previous == 0 ? 0 : (change / previous) * 100

        return StockQuote(
            symbol: symbol,
            displayName: (meta["shortName"] as? String)
                ?? presetName(for: symbol) ?? symbol,
            price: price,
            change: change,
            changePercent: percent,
            currency: (meta["currency"] as? String) ?? "",
            marketState: (meta["marketState"] as? String) ?? "")
    }

    nonisolated private static func presetName(for symbol: String) -> String? {
        for group in presets {
            if let match = group.tickers.first(where: { $0.0 == symbol }) { return match.1 }
        }
        return nil
    }
}
