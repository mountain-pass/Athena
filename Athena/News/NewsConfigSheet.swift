import SwiftUI

/// News Monitor settings — master-detail:
/// left = topic list, right = selected topic's sources + suggestions,
/// bottom = automation (24/7 collection, daily brief).
struct NewsConfigSheet: View {
    @ObservedObject var news: NewsStore
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var suggester: SourceSuggester
    @State private var selectedTopicID: String?
    @State private var newTopicName = ""
    @State private var newSourceURL = ""

    init(news: NewsStore) {
        self.news = news
        // Suggester needs the same gateway the store uses.
        _suggester = StateObject(wrappedValue: SourceSuggester(gateway: news.gatewayRef))
    }

    private var selectedIndex: Int? {
        guard let id = selectedTopicID else { return nil }
        return news.topics.firstIndex { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("News Monitor").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }
            .padding(16)

            Divider().overlay(Theme.border)

            // Master–detail
            HStack(spacing: 0) {
                topicList
                    .frame(width: 210)
                Divider().overlay(Theme.border)
                topicDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Theme.border)
            automationBar
        }
        .frame(width: 820, height: 640)
        .background(Theme.bg)
        .onAppear {
            if selectedTopicID == nil { selectedTopicID = news.topics.first?.id }
        }
        .onDisappear { news.fetchLatest(force: true) }
    }

    // MARK: Left — topic list

    private var topicList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(news.topics) { topic in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                selectedTopicID = topic.id
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(topic.enabled ? Theme.green : Theme.textFaint.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(topic.name)
                                    .font(Theme.mono(12, weight: selectedTopicID == topic.id ? .semibold : .regular))
                                    .foregroundStyle(topic.enabled ? Theme.text : Theme.textDim)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(topic.sources.count)")
                                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(selectedTopicID == topic.id ? Theme.panelAlt : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }

            Divider().overlay(Theme.border)

            // Add topic
            HStack(spacing: 6) {
                TextField("New topic…", text: $newTopicName)
                    .textFieldStyle(.plain).font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .onSubmit(addTopic)
                Button { addTopic() } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Theme.textFaint : Theme.amber)
                }
                .buttonStyle(.plain)
                .disabled(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private func addTopic() {
        let name = newTopicName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        news.addTopic(named: name)
        newTopicName = ""
        selectedTopicID = name
        // Niche topic? Ask the agent right away so suggestions are ready.
        if SourceSuggester.builtIn(for: name).isEmpty {
            suggester.askAgent(for: name)
        }
    }

    // MARK: Right — selected topic detail

    @ViewBuilder private var topicDetail: some View {
        if let index = selectedIndex {
            let topic = news.topics[index]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header row: name, enable, delete
                    HStack {
                        Text(topic.name.uppercased())
                            .font(Theme.mono(15, weight: .bold)).kerning(1)
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Toggle("Monitor", isOn: $news.topics[index].enabled)
                            .toggleStyle(.switch).tint(Theme.amber)
                            .font(Theme.mono(11))
                        Button(role: .destructive) {
                            let removed = news.topics[index]
                            news.deleteTopic(removed)
                            selectedTopicID = news.topics.first?.id
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Theme.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Delete topic")
                    }

                    // Active sources
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Sources (\(topic.sources.count))")
                        if topic.sources.isEmpty {
                            Text("No feeds yet — pick a suggestion below or paste a URL.")
                                .font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
                        }
                        ForEach(topic.sources, id: \.self) { source in
                            HStack(spacing: 8) {
                                Image(systemName: "dot.radiowaves.up.forward")
                                    .font(.system(size: 10)).foregroundStyle(Theme.green)
                                Text(source).font(Theme.mono(10.5)).foregroundStyle(Theme.textDim)
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    news.topics[index].sources.removeAll { $0 == source }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(Theme.red.opacity(0.7))
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }

                        HStack(spacing: 8) {
                            TextField("Paste an RSS/Atom feed URL…", text: $newSourceURL)
                                .textFieldStyle(.plain).font(Theme.mono(11))
                                .foregroundStyle(Theme.text)
                                .padding(8).background(Theme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .onSubmit { addSource(at: index) }
                            Button("ADD") { addSource(at: index) }
                                .buttonStyle(.plain).font(Theme.label).kerning(1)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Theme.amber).clipShape(Capsule())
                                .foregroundStyle(.black)
                        }
                    }

                    // Suggestions
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SectionLabel(text: "Suggested Feeds")
                            Spacer()
                            if suggester.loadingTopics.contains(topic.name) {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small).scaleEffect(0.7)
                                    Text("asking Athena…")
                                        .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                                }
                            } else {
                                Button {
                                    suggester.askAgent(for: topic.name)
                                } label: {
                                    Label("ASK ATHENA", systemImage: "sparkles")
                                        .font(Theme.label).kerning(1)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Theme.panelAlt).clipShape(Capsule())
                                        .foregroundStyle(Theme.amber)
                                }
                                .buttonStyle(.plain)
                                .help("Have the agent find free feeds for this topic")
                            }
                        }

                        let suggestions = suggester.suggestions(for: topic)
                        if suggestions.isEmpty && !suggester.loadingTopics.contains(topic.name) {
                            Text("No suggestions yet for this topic — try Ask Athena.")
                                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                        }
                        ForEach(suggestions) { suggestion in
                            HStack(spacing: 8) {
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        news.topics[index].sources.append(suggestion.url)
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Theme.green)
                                }.buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.name)
                                        .font(Theme.mono(11, weight: .medium))
                                        .foregroundStyle(Theme.text)
                                    Text(suggestion.url)
                                        .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.panel.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }

                        if let error = suggester.lastError {
                            Text(error).font(Theme.mono(10)).foregroundStyle(Theme.red)
                        }
                    }
                }
                .padding(18)
            }
        } else {
            VStack {
                Spacer()
                Text("Select or add a topic").font(Theme.mono(12)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func addSource(at index: Int) {
        let url = newSourceURL.trimmingCharacters(in: .whitespaces)
        guard url.hasPrefix("http"), !news.topics[index].sources.contains(url) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            news.topics[index].sources.append(url)
        }
        newSourceURL = ""
    }

    // MARK: Bottom — automation

    private var automationBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1 — the two automations, side by side, never compressed.
            HStack(spacing: 24) {
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { news.backgroundCollection },
                        set: { news.enableBackgroundCollection(hourly: $0) }))
                        .toggleStyle(.switch).tint(Theme.amber).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("24/7 collection")
                            .font(Theme.mono(11, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .fixedSize()
                        Text("gateway fetches hourly, even while this Mac sleeps")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                            .fixedSize()
                    }
                }

                Divider().overlay(Theme.border).frame(height: 28)

                HStack(spacing: 8) {
                    Text("Daily brief at")
                        .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                        .fixedSize()
                    Picker("", selection: $news.briefHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden().frame(width: 84)
                    Toggle(isOn: $news.allowBrowsing) {
                        Text("web fallback")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                            .fixedSize()
                    }
                    .toggleStyle(.checkbox)
                }

                Spacer(minLength: 0)
            }

            // Row 2 — status + action.
            HStack(spacing: 12) {
                if let status = news.syncStatus {
                    Text(status).font(Theme.mono(10))
                        .foregroundStyle(status.hasPrefix("✓") ? Theme.green : Theme.red)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Button {
                    news.syncToGateway()
                } label: {
                    Text("SAVE & SCHEDULE").font(Theme.label).kerning(1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.amber).clipShape(Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
