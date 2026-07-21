import SwiftUI

/// Scrolling market ticker, Bloomberg-style, pinned under the top bar.
struct StockTickerBar: View {
    @ObservedObject var stocks: StockStore

    var body: some View {
        HStack(spacing: 0) {
            // Static label
            HStack(spacing: 6) {
                Circle()
                    .fill(stocks.refreshing ? Theme.amber : Theme.green)
                    .frame(width: 5, height: 5)
                Text("MARKETS").font(Theme.mono(8, weight: .bold)).kerning(1.2)
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(Theme.panelAlt)

            if stocks.quotes.isEmpty {
                Text(stocks.refreshing ? "loading quotes…" : "no tickers configured")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                Marquee(quotes: stocks.quotes)
            }

            if let last = stocks.lastUpdate {
                Text(last, format: .dateTime.hour().minute())
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 10)
            }
            Button { stocks.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9)).foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
        }
        .frame(height: 26)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
        .task { stocks.refresh() }
    }
}

/// Continuously scrolling quote strip — never stops, including on hover.
private struct Marquee: View {
    let quotes: [StockQuote]
    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                // Two copies side by side give a seamless wrap.
                let width = measuredWidth > 0 ? measuredWidth : estimatedWidth
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let offset = -CGFloat(elapsed * 34).truncatingRemainder(dividingBy: max(1, width))

                HStack(spacing: 0) {
                    strip
                        .background(
                            // Measure one copy so the wrap point is exact.
                            GeometryReader { proxy in
                                Color.clear.onAppear { measuredWidth = proxy.size.width }
                                    .onChange(of: proxy.size.width) { _, new in
                                        measuredWidth = new
                                    }
                            }
                        )
                    strip
                }
                .offset(x: offset)
            }
            .frame(height: geo.size.height)
            .clipped()
        }
    }

    private var estimatedWidth: CGFloat {
        quotes.reduce(0) { $0 + CGFloat($1.displayName.count) * 6.2 + 96 }
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(quotes) { quote in
                HStack(spacing: 6) {
                    Text(quote.displayName)
                        .font(Theme.mono(10, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(quote.priceLabel)
                        .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                    HStack(spacing: 2) {
                        Image(systemName: quote.isUp ? "arrowtriangle.up.fill"
                                                     : "arrowtriangle.down.fill")
                            .font(.system(size: 6))
                        Text(quote.changeLabel).font(Theme.mono(10, weight: .medium))
                    }
                    .foregroundStyle(quote.isUp ? Theme.green : Theme.red)
                }
                .padding(.horizontal, 14)
                .help("\(quote.symbol) · \(quote.currency) \(quote.priceLabel)")
            }
        }
        .fixedSize()
    }
}
