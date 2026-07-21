import SwiftUI

/// Daily Hotspot Monitor — rotating Earth with geo-tagged story targets,
/// topic columns flanking it, and a resizable chat dock on the right.
struct NewsView: View {
    @ObservedObject var news: NewsStore
    @EnvironmentObject var app: AppState

    @State private var selectedItem: NewsItem?
    @State private var selectedHotspot: GeoHotspot?
    @State private var showConfig = false
    @AppStorage("news.chatWidth") private var chatWidth: Double = 340

    private let minChat: Double = 280
    private let maxChat: Double = 720

    var body: some View {
        GeometryReader { geo in
            let clampedChat = min(max(chatWidth, minChat), min(maxChat, geo.size.width - 420))
            HStack(spacing: 0) {
                monitorPane(availableWidth: geo.size.width - clampedChat - 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ResizeHandle(width: $chatWidth, min: minChat,
                             max: min(maxChat, geo.size.width - 420))
                chatPane
                    .frame(width: clampedChat)
            }
        }
        .sheet(item: $selectedItem) { item in
            NewsDetailView(item: item,
                           onPin: { app.carousel.pin(item) }) { prompt in
                app.chat.send(text: prompt)
                selectedItem = nil
            }
        }
        .sheet(isPresented: $showConfig) { NewsConfigSheet(news: news) }
        .task {
            news.fetchLatest()
            news.startAutoRefresh(every: 15)
        }
        .animation(.easeInOut(duration: 0.3), value: news.fetching)
        .animation(.easeInOut(duration: 0.3), value: news.newlyArchived)
    }

    // MARK: Monitor (globe + topic columns)

    private func monitorPane(availableWidth: CGFloat) -> some View {
        // Below ~820pt there isn't room for globe + two column stacks.
        let showGlobe = availableWidth > 820
        let columns = news.enabledTopics
        let half = Int(ceil(Double(columns.count) / 2))
        let left = Array(columns.prefix(half))
        let right = Array(columns.dropFirst(half))

        return VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)

            // Widgets live inside the monitor pane — the chat dock keeps
            // full window height alongside them.
            if app.stocks.enabled {
                StockTickerBar(stocks: app.stocks)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if columns.isEmpty {
                emptyState("No topics enabled — open the gear above the chat to add some.")
            } else if showGlobe {
                HStack(alignment: .top, spacing: 12) {
                    columnStack(left)
                        .frame(width: 260)
                    globeCenter
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    columnStack(right)
                        .frame(width: 260)
                }
                .padding(12)
            } else {
                // Narrow: drop the globe, flow columns in a grid.
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420),
                                                 spacing: 12, alignment: .top)],
                              alignment: .leading, spacing: 12) {
                        ForEach(columns) { topic in
                            TopicColumn(topic: topic, items: news.itemsFor(topic.name)) {
                                selectedItem = $0
                            }
                        }
                    }
                    .padding(12)
                }
            }

            if app.carousel.enabled {
                CarouselBar(carousel: app.carousel) { prompt in
                    app.chat.send(text: prompt)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .panel()
        .animation(.easeInOut(duration: 0.25), value: app.stocks.enabled)
        .animation(.easeInOut(duration: 0.25), value: app.carousel.enabled)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Daily Hotspot Monitor", color: Theme.amber)
                Text("Let signals surface on their own.")
                    .font(Theme.mono(15, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Spacer()
            HStack(spacing: 10) {
                Label("\(news.items.count) stories", systemImage: "square.stack.3d.up")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                Label("\(GeoTagger.hotspots(from: news.items).count) regions", systemImage: "mappin.and.ellipse")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                if news.newlyArchived > 0 {
                    Label("+\(news.newlyArchived) archived", systemImage: "internaldrive")
                        .font(Theme.mono(10)).foregroundStyle(Theme.green)
                        .transition(.scale.combined(with: .opacity))
                }
                if news.fetching {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("fetching…").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    }
                    .transition(.opacity)
                } else if let last = news.lastFetched {
                    Text("updated \(last, format: .dateTime.hour().minute())")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
                Button { news.fetchLatest(force: true) } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain).help("Refresh feeds")
            }
        }
        .padding(16)
    }

    private var globeCenter: some View {
        ZStack {
            WorldGlobeView(hotspots: GeoTagger.hotspots(from: news.items),
                           selected: $selectedHotspot)

            // Region detail card
            if let spot = selectedHotspot {
                VStack {
                    Spacer()
                    HotspotCard(hotspot: spot,
                                onSelect: { selectedItem = $0 },
                                onClose: { selectedHotspot = nil })
                        .padding(.bottom, 8)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: selectedHotspot)
    }

    private func columnStack(_ topics: [NewsTopic]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(topics) { topic in
                    TopicColumn(topic: topic, items: news.itemsFor(topic.name)) {
                        selectedItem = $0
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(Theme.mono(12)).foregroundStyle(Theme.textFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Chat dock (with AI BRIEF + gear on top)

    private var chatPane: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: "Ask Athena", color: Theme.amber)
                Spacer()
                Button {
                    news.summarizeSinceLastTalk(chat: app.chat)
                } label: {
                    Text("SINCE LAST TALK").font(Theme.label).kerning(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.panelAlt).clipShape(Capsule())
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
                .help("Summarize from the agent's stored archive — no re-fetching")

                Button {
                    news.runNow(chat: app.chat)
                } label: {
                    Text("AI BRIEF").font(Theme.label).kerning(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.amber).clipShape(Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .help("Full brief — the agent fetches and summarizes fresh")
                Button { showConfig = true } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .help("Configure topics, sources, schedule")
            }
            .padding(.horizontal, 4)

            ChatView(chat: app.chat)
        }
    }
}

// MARK: - Drag-to-resize handle

private struct ResizeHandle: View {
    @Binding var width: Double
    let min: Double
    let max: Double
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.amber.opacity(0.5) : Theme.border)
            .frame(width: hovering ? 3 : 1)
            .frame(width: 8)                    // generous hit area
            .contentShape(Rectangle())
            .onHover { hovering = $0; if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        // Dragging left widens the chat.
                        width = Swift.min(Swift.max(width - value.translation.width, min), max)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Hotspot detail card

private struct HotspotCard: View {
    let hotspot: GeoHotspot
    let onSelect: (NewsItem) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Theme.red).frame(width: 6, height: 6)
                Text(hotspot.place.name.uppercased())
                    .font(Theme.mono(11, weight: .bold)).kerning(1.2)
                    .foregroundStyle(Theme.text)
                Text("\(hotspot.items.count) stories")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                        .foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(hotspot.items.prefix(8)) { item in
                        Button { onSelect(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(Theme.mono(11)).foregroundStyle(Theme.text)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                HStack(spacing: 6) {
                                    Text(item.topic).font(Theme.mono(9)).foregroundStyle(Theme.amber)
                                    Text(item.source).font(Theme.mono(9)).foregroundStyle(Theme.blue)
                                    if !item.ageLabel.isEmpty {
                                        Text(item.ageLabel).font(Theme.mono(9))
                                            .foregroundStyle(Theme.textFaint)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(Theme.panel.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.red.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

// MARK: - Topic column

struct TopicColumn: View {
    let topic: NewsTopic
    let items: [NewsItem]
    let onSelect: (NewsItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Theme.red).frame(width: 6, height: 6)
                Text(topic.name.uppercased())
                    .font(Theme.mono(11, weight: .bold)).kerning(1.5)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("hotdata · \(items.count)")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
            }
            if items.isEmpty {
                Text("no stories fetched").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
            }
            ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { rank, item in
                Button { onSelect(item) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(rank + 1)")
                            .font(Theme.mono(11, weight: .bold))
                            .foregroundStyle(rank < 3 ? Theme.amber : Theme.textFaint)
                            .frame(width: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Text(item.source).font(Theme.mono(9)).foregroundStyle(Theme.blue)
                                if !item.ageLabel.isEmpty {
                                    Text(item.ageLabel).font(Theme.mono(9))
                                        .foregroundStyle(Theme.textFaint)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Detail sheet

struct NewsDetailView: View {
    let item: NewsItem
    var onPin: (() -> Void)?
    let onAskAthena: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: item.topic, color: Theme.amber)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }
            Text(item.title)
                .font(Theme.mono(17, weight: .bold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(item.source).font(Theme.mono(10)).foregroundStyle(Theme.blue)
                if let date = item.date {
                    Text(date, format: .dateTime.day().month().hour().minute())
                        .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
                if let place = GeoTagger.place(for: item) {
                    Label(place.name, systemImage: "mappin")
                        .font(Theme.mono(10)).foregroundStyle(Theme.red)
                }
            }
            ScrollView {
                Text(item.summary.isEmpty
                     ? "No summary in feed — open the article or ask Athena."
                     : item.summary)
                    .font(Theme.mono(12)).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            HStack(spacing: 10) {
                if let link = item.link {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Label("OPEN ARTICLE", systemImage: "safari")
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.panelAlt).clipShape(Capsule())
                            .foregroundStyle(Theme.text)
                    }.buttonStyle(.plain)
                }
                if let onPin {
                    Button {
                        onPin(); pinned = true
                    } label: {
                        Label(pinned ? "PINNED" : "PIN TO WATCHLIST",
                              systemImage: pinned ? "checkmark" : "pin")
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(pinned ? Theme.green.opacity(0.2) : Theme.panelAlt)
                            .clipShape(Capsule())
                            .foregroundStyle(pinned ? Theme.green : Theme.text)
                    }
                    .buttonStyle(.plain)
                    .disabled(pinned)
                }
                Button {
                    let link = item.link?.absoluteString ?? ""
                    onAskAthena("Summarize this article and give me the key takeaways:\n\(item.title)\n\(link)")
                } label: {
                    Label("ASK ATHENA", systemImage: "sparkles")
                        .font(Theme.label).kerning(1)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.amber).clipShape(Capsule())
                        .foregroundStyle(.black)
                }.buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.bg)
    }
}

