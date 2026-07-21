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
            NewsDetailView(item: item) { prompt in
                app.chat.send(text: prompt)
                selectedItem = nil
            }
        }
        .sheet(isPresented: $showConfig) { NewsConfigSheet(news: news) }
        .task { news.fetchLatest() }
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
        }
        .panel()
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
                if news.fetching {
                    ProgressView().controlSize(.small)
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
                    news.runNow(chat: app.chat)
                } label: {
                    Text("AI BRIEF").font(Theme.label).kerning(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.amber).clipShape(Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .help("Ask the agent to summarize today's stories")
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
    let onAskAthena: (String) -> Void
    @Environment(\.dismiss) private var dismiss

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

// MARK: - Config sheet (gear)

struct NewsConfigSheet: View {
    @ObservedObject var news: NewsStore
    @Environment(\.dismiss) private var dismiss
    @State private var newTopicName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("News Monitor Settings").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Topics")
                    ForEach($news.topics) { $topic in
                        EditableTopicCard(topic: $topic) { news.deleteTopic(topic) }
                    }
                    HStack {
                        TextField("New topic name (e.g. Crypto, Gaming, Space)…", text: $newTopicName)
                            .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.text)
                            .padding(8).background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onSubmit(addTopic)
                        Button("ADD TOPIC") { addTopic() }
                            .buttonStyle(.plain).font(Theme.label).kerning(1)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.amber).clipShape(Capsule())
                            .foregroundStyle(.black)
                    }

                    Divider().overlay(Theme.border).padding(.vertical, 4)

                    SectionLabel(text: "Daily AI Brief")
                    HStack(spacing: 12) {
                        Text("Deliver at").font(Theme.body).foregroundStyle(Theme.textDim)
                        Picker("", selection: $news.briefHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .labelsHidden().frame(width: 90)
                        Toggle(isOn: $news.allowBrowsing) {
                            Text("Allow web browsing fallback")
                                .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                        }.toggleStyle(.checkbox)
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        Button { news.syncToGateway() } label: {
                            Text("SAVE & SCHEDULE ON GATEWAY").font(Theme.label).kerning(1)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Theme.amber).clipShape(Capsule())
                                .foregroundStyle(.black)
                        }.buttonStyle(.plain)
                        if let status = news.syncStatus {
                            Text(status).font(Theme.mono(10))
                                .foregroundStyle(status.hasPrefix("✓") ? Theme.green : Theme.textDim)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .background(Theme.bg)
        .onDisappear { news.fetchLatest(force: true) }
    }

    private func addTopic() {
        news.addTopic(named: newTopicName)
        newTopicName = ""
    }
}

private struct EditableTopicCard: View {
    @Binding var topic: NewsTopic
    let onDelete: () -> Void
    @State private var expanded = false
    @State private var newSource = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $topic.enabled)
                    .toggleStyle(.switch).tint(Theme.amber).labelsHidden()
                Text(topic.name.uppercased())
                    .font(Theme.mono(12, weight: .semibold)).kerning(1)
                    .foregroundStyle(topic.enabled ? Theme.text : Theme.textFaint)
                Spacer()
                Text("\(topic.sources.count) sources")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
                Button { onDelete() } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                        .foregroundStyle(Theme.red.opacity(0.8))
                }.buttonStyle(.plain)
            }
            if expanded {
                ForEach(topic.sources, id: \.self) { source in
                    HStack {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.system(size: 9)).foregroundStyle(Theme.green)
                        Text(source).font(Theme.mono(9)).foregroundStyle(Theme.textDim)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { topic.sources.removeAll { $0 == source } } label: {
                            Image(systemName: "xmark").font(.system(size: 8))
                                .foregroundStyle(Theme.textFaint)
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Add RSS/Atom feed URL…", text: $newSource)
                        .textFieldStyle(.plain).font(Theme.mono(10)).foregroundStyle(Theme.text)
                        .padding(6).background(Theme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onSubmit(addSource)
                    Button("Add") { addSource() }
                        .buttonStyle(.plain).font(Theme.mono(10)).foregroundStyle(Theme.amber)
                }
            }
        }
        .padding(12)
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func addSource() {
        let trimmed = newSource.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { topic.sources.append(trimmed); newSource = "" }
    }
}
