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

    @AppStorage("setupComplete") var setupComplete = false
    @Published var selectedTab: MainTab = .chat

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Auto-connect on launch when setup is done.
        if setupComplete {
            gateway.connect()
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
