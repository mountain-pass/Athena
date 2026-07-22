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
                // News and Jobs are full-width workspaces — the orb/todo column
                // is chat furniture and only crowds them.
                if app.selectedTab == .chat {
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
        // Listening/speaking feedback on every tab, not just Chat.
        .overlay { VoiceHUD() }
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

// MARK: Athena mark (coin logo)

/// Uses the AthenaLogo asset when present; falls back to a drawn emblem so the
/// app still builds and looks intentional before you run Scripts/make-icon.swift.
struct AthenaMark: View {
    var size: CGFloat = 84

    private var hasAsset: Bool { NSImage(named: "AthenaLogo") != nil }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.amber.opacity(0.18), .clear],
                                     center: .center, startRadius: size * 0.2,
                                     endRadius: size * 0.62))
            if hasAsset {
                Image("AthenaLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [Theme.amber, Theme.amberDim],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 2)
                    .overlay(
                        Image(systemName: "laurel.leading")
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(Theme.amber)
                    )
                    .padding(2)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.amber.opacity(0.25), radius: 8)
    }
}

// MARK: Offline banner

private struct OfflineBanner: View {
    @EnvironmentObject var gateway: GatewayClient
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.red).frame(width: 7, height: 7)
            Text(gateway.state == .connecting
                 ? "Reconnecting to gateway…"
                 : (gateway.lastError ?? "Gateway offline"))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("· work continues on the gateway")
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
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
            VStack(spacing: 10) {
                AthenaMark(size: 84)
                VStack(spacing: 3) {
                    SectionLabel(text: "Cognition Interface")
                    Text("Athena AI Agent").font(Theme.title).foregroundStyle(Theme.text)
                    if case .connected(let version) = gateway.state {
                        Text("gateway v\(version)")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .panel()

            // Live voice orb — reacts to mic input and TTS output.
            VoiceOrbPanel()

            // Shared todo list — fills whatever height is left.
            TodoPanel(todos: app.todos)
                .frame(maxHeight: .infinity)
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
