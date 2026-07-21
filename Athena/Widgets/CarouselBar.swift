import SwiftUI

/// Bottom card carousel — pinned stories, auto-surfaced topic highlights,
/// and the user's own notes.
struct CarouselBar: View {
    @ObservedObject var carousel: CarouselStore
    var onAsk: ((String) -> Void)?

    @State private var selected: CarouselCard?

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                SectionLabel(text: "Watchlist", color: Theme.amber)
                Text("\(carousel.cards.count) cards")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)

            if carousel.cards.isEmpty {
                Text("Pin a story from the globe or a topic column, or add a note in Settings → Widgets.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(carousel.cards) { card in
                            CardView(card: card,
                                     onOpen: { selected = card },
                                     onRemove: { carousel.remove(card) })
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Theme.panel.opacity(0.5))
        .sheet(item: $selected) { card in
            CardDetailSheet(card: card,
                            onAsk: onAsk,
                            onRemove: { carousel.remove(card) })
        }
    }
}

/// Full card view — same shape as the news detail modal.
private struct CardDetailSheet: View {
    let card: CarouselCard
    var onAsk: ((String) -> Void)?
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(card.color).frame(width: 6, height: 6)
                    Text(card.subtitle.uppercased())
                        .font(Theme.label).kerning(1).foregroundStyle(card.color)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }

            Text(card.title)
                .font(Theme.mono(17, weight: .bold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(card.createdAt, format: .dateTime.day().month().hour().minute())
                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)

            if !card.detail.isEmpty {
                ScrollView {
                    Text(card.detail)
                        .font(Theme.mono(12)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            } else {
                Text("No detail on this card — open the source or ask Athena.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
            }

            HStack(spacing: 10) {
                if let link = card.link, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("OPEN", systemImage: "safari")
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.panelAlt).clipShape(Capsule())
                            .foregroundStyle(Theme.text)
                    }.buttonStyle(.plain)
                }
                Button {
                    onAsk?("Tell me more about this: \(card.title)\n\(card.link ?? "")")
                    dismiss()
                } label: {
                    Label("ASK ATHENA", systemImage: "sparkles")
                        .font(Theme.label).kerning(1)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.amber).clipShape(Capsule())
                        .foregroundStyle(.black)
                }.buttonStyle(.plain)
                Spacer()
                Button {
                    onRemove(); dismiss()
                } label: {
                    Label("REMOVE", systemImage: "trash")
                        .font(Theme.label).kerning(1)
                        .foregroundStyle(Theme.red.opacity(0.85))
                }.buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.bg)
    }
}

private struct CardView: View {
    let card: CarouselCard
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(card.color).frame(width: 5, height: 5)
                Text(card.subtitle.uppercased())
                    .font(Theme.mono(8, weight: .medium)).kerning(0.8)
                    .foregroundStyle(card.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering {
                    Button { onRemove() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7)).foregroundStyle(Theme.textFaint)
                    }.buttonStyle(.plain)
                }
            }

            Text(card.title)
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if hovering {
                Text("click to open")
                    .font(Theme.mono(8)).foregroundStyle(Theme.textFaint)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .frame(width: 210, height: 96, alignment: .topLeading)
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(hovering ? card.color.opacity(0.55) : Theme.border, lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.02 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
