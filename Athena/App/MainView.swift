import SwiftUI

/// Main window: Bailongma-style three-column cognition interface.
/// Left: agent card + live voice orb. Center: active tab. Right: live dashboard.
struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var gateway: GatewayClient

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.border)
            if !gateway.state.isConnected {
                OfflineBanner()
                if let pairing = gateway.pairingInstructions {
                    Text(pairing)
                        .font(Theme.mono(11)).foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.amber.opacity(0.08))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                if app.selectedTab != .news {
                    LeftColumn()
                        .frame(width: 260)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                centerContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if app.selectedTab == .chat {
                    RightColumn()
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(12)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: app.selectedTab)
        }
        .background(Theme.bg)
        .onAppear { app.voice.requestPermissions() }
    }

    @ViewBuilder private var centerContent: some View {
        ZStack {
            switch app.selectedTab {
            case .chat:
                ChatView(chat: app.chat)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .news:
                NewsView(news: app.news)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .jobs:
                JobsView(jobs: app.jobs)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

// MARK: Top bar

private struct TopBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var gateway: GatewayClient

    var body: some View {
        HStack(spacing: 16) {
            Text("ATHENA / LIVE COGNITION")
                .font(Theme.label).kerning(2).foregroundStyle(Theme.textDim)

            Spacer()

            // Tab switcher
            HStack(spacing: 4) {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        app.selectedTab = tab
                    } label: {
                        Label(tab.rawValue.uppercased(), systemImage: tab.icon)
                            .font(Theme.label).kerning(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(app.selectedTab == tab ? Theme.panelAlt : .clear)
                            .clipShape(Capsule())
                            .foregroundStyle(app.selectedTab == tab ? Theme.amber : Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            StatusDot(on: gateway.state.isConnected,
                      label: gateway.state.isConnected ? "CONNECTED" : "OFFLINE")
            Text("LOCAL · PRIVATE").font(Theme.label).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: Offline banner

private struct OfflineBanner: View {
    @EnvironmentObject var gateway: GatewayClient
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.red).frame(width: 7, height: 7)
            Text(gateway.state == .connecting ? "Reconnecting to gateway…"
                 : "Gateway offline\(gateway.lastError.map { " — \($0)" } ?? "")")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                gateway.connect()
            } label: {
                Text("RECONNECT NOW").font(Theme.label).kerning(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.amber).clipShape(Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            Button {
                app.resetSetup()
            } label: {
                Text("EDIT CONNECTION").font(Theme.label).kerning(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.panelAlt).clipShape(Capsule())
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }
}

// MARK: Left column

private struct LeftColumn: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var gateway: GatewayClient

    var body: some View {
        VStack(spacing: 12) {
            // Agent identity card
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Theme.amber.opacity(0.15)).frame(width: 38, height: 38)
                        Image(systemName: "sparkles").foregroundStyle(Theme.amber)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(text: "Cognition Interface")
                        Text("Athena AI Agent").font(Theme.title).foregroundStyle(Theme.text)
                    }
                }
                HStack {
                    SectionLabel(text: "Message Processor")
                    Spacer()
                    Text("LIVE").font(Theme.label)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.blue.opacity(0.15)).clipShape(Capsule())
                        .foregroundStyle(Theme.blue)
                }
                if case .connected(let version) = gateway.state {
                    Text("gateway v\(version)").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()

            // Live voice orb — reacts to mic input and TTS output.
            VoiceOrbPanel()

            Spacer()
        }
    }
}

// MARK: Right column

private struct RightColumn: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 12) {
            StatsStrip(chat: app.chat, activity: app.activity)
            HeartbeatPanel(activity: app.activity)
            ActionLogPanel(activity: app.activity)
            CognitionPanel(activity: app.activity, chat: app.chat)
        }
    }
}
