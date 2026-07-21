import SwiftUI
import Combine

/// Global app state: owns the gateway connection, voice engine, and feature stores.
@MainActor
final class AppState: ObservableObject {
    let gateway = GatewayClient()
    let voice = VoiceManager()

    lazy var chat = ChatStore(gateway: gateway, voice: voice)
    lazy var news = NewsStore(gateway: gateway)
    lazy var jobs = JobsStore(gateway: gateway)
    lazy var activity = ActivityStore(gateway: gateway)
    lazy var provisioner = AgentProvisioner(gateway: gateway)
    let stocks = StockStore()
    let carousel = CarouselStore()
    lazy var todos = TodoStore(gateway: gateway)

    @AppStorage("setupComplete") var setupComplete = false
    @Published var selectedTab: MainTab = .chat

    private var cancellables = Set<AnyCancellable>()

    private var handshakeDone = false

    init() {
        // Auto-connect on launch when setup is done.
        if setupComplete {
            gateway.connect()
        }

        // Contract handshake: once per launch, right after connecting. Asks the
        // agent whether it already knows the Athena contract and only sends the
        // setup manual when it doesn't — so ordinary messages stay lean.
        gateway.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.name == "athena.connected", !self.handshakeDone else { return }
                self.handshakeDone = true
                Task {
                    let result = await self.provisioner.verifyOrProvision(
                        news: self.news, todos: self.todos)
                    if case .failed = result { return }
                    self.chat.agentProvisioned = true
                    // Pull anything the agent produced while the app was closed.
                    await self.news.loadFromAgentMemory()
                    self.todos.pushToAgent()
                    await self.todos.pullAgentUpdates()
                }
            }
            .store(in: &cancellables)
        // Warm the TTS model in the background so the first spoken reply
        // isn't waiting on a cold model load (the biggest source of lag).
        if voice.engine == .kokoro, voice.kokoro.isDownloaded {
            let kokoro = voice.kokoro          // capture the value, not self
            Task.detached(priority: .utility) {
                await kokoro.prepare()
            }
        }

        // Reconnect recovery: flush anything deferred while offline and
        // catch up on what the agent did in the meantime.
        gateway.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.name == "athena.connected" else { return }
                self.todos.resumeAfterReconnect()
                Task { await self.news.loadFromAgentMemory() }
            }
            .store(in: &cancellables)

        // Keep carousel auto-topic cards in step with fetched stories.
        news.onItemsUpdated = { [weak self] items in
            self?.carousel.syncAutoTopics(from: items)
        }

        // Speak assistant replies out loud only when the turn was initiated by voice.
        voice.onTranscriptFinal = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.chat.send(text: text, viaVoice: true)
        }
    }

    func completeSetup(with settings: ConnectionSettings) {
        gateway.connect(settings)
        setupComplete = true
        // Teach the agent its role as soon as we're connected — Athena is only
        // a UI; the contract has to live on the gateway side.
        Task {
            for _ in 0..<40 {
                if gateway.state.isConnected { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard gateway.state.isConnected else { return }
            await provisioner.provision(news: news)
            chat.agentProvisioned = true
        }
    }

    func resetSetup() {
        setupComplete = false
        gateway.disconnect()
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case news = "News"
    case jobs = "Jobs"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .news: "globe.americas"
        case .jobs: "calendar.badge.clock"
        }
    }
}
