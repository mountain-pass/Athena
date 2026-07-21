import SwiftUI

/// Settings → Widgets: market ticker and bottom carousel.
struct WidgetSettingsTab: View {
    @ObservedObject var stocks: StockStore
    @ObservedObject var carousel: CarouselStore
    @ObservedObject var news: NewsStore

    @State private var newTicker = ""
    @State private var noteTitle = ""
    @State private var noteDetail = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // ── Market ticker ─────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $stocks.enabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Market ticker").font(Theme.body).foregroundStyle(Theme.text)
                            Text("Scrolling prices under the top bar, refreshed every ~7 minutes")
                                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    .toggleStyle(.switch).tint(Theme.amber)

                    if stocks.enabled {
                        // Current tickers
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Tracking (\(stocks.symbols.count))")
                            FlowChips(items: stocks.symbols) { symbol in
                                stocks.remove(symbol)
                            }
                            HStack(spacing: 8) {
                                TextField("Add symbol — e.g. AAPL, BHP.AX, SHEL.L, 7203.T",
                                          text: $newTicker)
                                    .textFieldStyle(.plain).font(Theme.mono(11))
                                    .padding(8).background(Theme.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .onSubmit(addTicker)
                                Button("ADD") { addTicker() }
                                    .buttonStyle(.plain).font(Theme.label).kerning(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Theme.amber).clipShape(Capsule())
                                    .foregroundStyle(.black)
                            }
                            Text("Suffixes: none = US · .AX Australia · .L London · .T Tokyo · .HK Hong Kong · .DE Frankfurt · .PA Paris · .AS Amsterdam. Indices start with ^ (e.g. ^AXJO). Prices come from Yahoo Finance — free, no account.")
                                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Presets by market
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Quick add")
                            ForEach(StockStore.presets, id: \.market) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.market.uppercased())
                                        .font(Theme.mono(9, weight: .medium)).kerning(1)
                                        .foregroundStyle(Theme.textDim)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(group.tickers, id: \.0) { ticker in
                                                let added = stocks.symbols.contains(ticker.0)
                                                Button {
                                                    added ? stocks.remove(ticker.0)
                                                          : stocks.add(ticker.0)
                                                } label: {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: added ? "checkmark" : "plus")
                                                            .font(.system(size: 7))
                                                        Text(ticker.1).font(Theme.mono(10))
                                                    }
                                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                                    .background(added ? Theme.green.opacity(0.15)
                                                                      : Theme.panelAlt)
                                                    .clipShape(Capsule())
                                                    .foregroundStyle(added ? Theme.green : Theme.textDim)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Divider().overlay(Theme.border)

                // ── Carousel ──────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $carousel.enabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Watchlist carousel").font(Theme.body).foregroundStyle(Theme.text)
                            Text("Card strip along the bottom for things worth keeping in view")
                                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    .toggleStyle(.switch).tint(Theme.amber)

                    if carousel.enabled {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Auto-surface top story from")
                            FlowToggleChips(
                                items: news.topics.map(\.name),
                                selected: carousel.autoTopics
                            ) { topic in
                                if carousel.autoTopics.contains(topic) {
                                    carousel.autoTopics.remove(topic)
                                } else {
                                    carousel.autoTopics.insert(topic)
                                }
                                carousel.syncAutoTopics(from: news.items)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Add your own card")
                            TextField("Title", text: $noteTitle)
                                .textFieldStyle(.plain).font(Theme.mono(11))
                                .padding(8).background(Theme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            HStack(spacing: 8) {
                                TextField("Detail (optional)", text: $noteDetail)
                                    .textFieldStyle(.plain).font(Theme.mono(11))
                                    .padding(8).background(Theme.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                Button("ADD CARD") {
                                    guard !noteTitle.isEmpty else { return }
                                    carousel.addCustom(title: noteTitle, detail: noteDetail)
                                    noteTitle = ""; noteDetail = ""
                                }
                                .buttonStyle(.plain).font(Theme.label).kerning(1)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Theme.amber).clipShape(Capsule())
                                .foregroundStyle(.black)
                            }
                        }

                        if !carousel.cards.isEmpty {
                            HStack {
                                Text("\(carousel.cards.count) cards")
                                    .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                                Spacer()
                                Button("Clear all") { carousel.cards = [] }
                                    .font(Theme.mono(10)).foregroundStyle(Theme.red)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private func addTicker() {
        stocks.add(newTicker)
        newTicker = ""
    }
}

/// Removable chips.
struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        Text(item).font(Theme.mono(10)).foregroundStyle(Theme.text)
                        Button { onRemove(item) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7)).foregroundStyle(Theme.textFaint)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.panelAlt).clipShape(Capsule())
                }
            }
        }
    }
}

/// Multi-select chips.
struct FlowToggleChips: View {
    let items: [String]
    let selected: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    let isOn = selected.contains(item)
                    Button { onToggle(item) } label: {
                        Text(item).font(Theme.mono(10))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(isOn ? Theme.green.opacity(0.18) : Theme.panelAlt)
                            .clipShape(Capsule())
                            .foregroundStyle(isOn ? Theme.green : Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
