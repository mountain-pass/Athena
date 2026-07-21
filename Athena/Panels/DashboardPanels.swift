import SwiftUI

// MARK: Stats strip — STATUS · TOK/S · TOKENS · TICKS (Bailongma-style)

struct StatsStrip: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var activity: ActivityStore
    @EnvironmentObject var gateway: GatewayClient

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 0) {
                stat("STATUS",
                     gateway.state.isConnected ? "LIVE" : "OFF",
                     gateway.state.isConnected ? Theme.green : Theme.red)
                divider
                stat("TOK/S", chat.tokensPerSecond > 0
                     ? String(format: "%.1f", chat.tokensPerSecond) : "—",
                     chat.agentBusy ? Theme.amber : Theme.text)
                divider
                stat("TOKENS", chat.totalTurnTokens > 0
                     ? compact(chat.totalTurnTokens) : "0", Theme.text)
                divider
                stat("MSGS", "\(chat.messages.count)", Theme.text)
                divider
                stat("TICKS", "\(activity.heartbeatCount)", Theme.text)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .panel()
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 26)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label).font(Theme.mono(8, weight: .medium)).kerning(1)
                .foregroundStyle(Theme.textFaint)
            Text(value).font(Theme.mono(13, weight: .bold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: Heartbeat panel — "consciousness heartbeat" ECG line

struct HeartbeatPanel: View {
    @ObservedObject var activity: ActivityStore
    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Heartbeat", color: Theme.amber)
                Spacer()
                if let last = activity.lastHeartbeat {
                    Text(last, style: .relative).font(Theme.label).foregroundStyle(Theme.textFaint)
                } else {
                    Text("WAITING").font(Theme.label).foregroundStyle(Theme.textFaint)
                }
            }
            ECGLine(beat: activity.heartbeatCount)
                .frame(height: 56)
            HStack {
                Text("\(activity.heartbeatCount) ticks")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                Spacer()
            }
        }
        .padding(14)
        .panel()
    }
}

/// Scrolling flatline with a spike each time `beat` increments.
struct ECGLine: View {
    var beat: Int
    @State private var lastBeat = 0
    @State private var spikeTime: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                let spikeAge = spikeTime.map { timeline.date.timeIntervalSince($0) } ?? 99
                for x in stride(from: 0.0, to: size.width, by: 2) {
                    let progress = x / size.width
                    var y = midY + sin((progress * 20 + t) * 2) * 1.5 // idle wobble
                    // Spike travels left→right for ~1.2s after a beat.
                    if spikeAge < 1.2 {
                        let spikeX = spikeAge / 1.2 * size.width
                        let d = abs(x - spikeX)
                        if d < 30 {
                            let intensity = (1 - d / 30)
                            y -= intensity * intensity * size.height * 0.42
                            if d < 10 { y += intensity * size.height * 0.18 } // dip
                        }
                    }
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                context.stroke(path, with: .color(Theme.amber), lineWidth: 1.5)
            }
            .background(GridBackground())
        }
        .onChange(of: beat) { _, new in
            if new != lastBeat { lastBeat = new; spikeTime = .now }
        }
    }
}

struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 14
            var path = Path()
            for x in stride(from: 0.0, to: size.width, by: step) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.0, to: size.height, by: step) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Theme.border.opacity(0.5)), lineWidth: 0.5)
        }
    }
}

// MARK: Action log

struct ActionLogPanel: View {
    @ObservedObject var activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Action Log")
            if activity.actionLog.isEmpty {
                Text("No activity yet").font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(activity.actionLog.suffix(12).reversed()) { entry in
                        ActivityRow(entry: entry, tint: Theme.amber)
                    }
                }
            }
            .frame(maxHeight: 170)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

// MARK: Live cognition (thinking + tools)

struct CognitionPanel: View {
    @ObservedObject var activity: ActivityStore
    @ObservedObject var chat: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Live Cognition")
                Spacer()
                if chat.agentBusy {
                    ProgressView().controlSize(.small).tint(Theme.amber)
                }
            }
            if activity.cognition.isEmpty {
                Text("Thinking & tools will appear here")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(activity.cognition.suffix(12).reversed()) { entry in
                        ActivityRow(entry: entry, tint: Theme.green)
                    }
                }
            }
            .frame(maxHeight: 170)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(Theme.mono(11)).foregroundStyle(Theme.text)
                if let d = entry.detail {
                    Text(d).font(Theme.mono(10)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
            }
            Spacer()
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
        }
    }
}
