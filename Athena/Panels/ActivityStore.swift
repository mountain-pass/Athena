import Foundation
import Combine

struct ActivityEntry: Identifiable {
    let id = UUID()
    let icon: String       // SF Symbol
    let title: String
    let detail: String?
    let date: Date
}

/// Feeds the right-hand dashboard: heartbeat ticks, action log, live cognition.
@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var actionLog: [ActivityEntry] = []
    @Published private(set) var cognition: [ActivityEntry] = []
    @Published private(set) var heartbeatTimes: [Date] = []
    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var heartbeatCount = 0

    private let gateway: GatewayClient
    private var cancellables = Set<AnyCancellable>()
    private let cap = 60

    init(gateway: GatewayClient) {
        self.gateway = gateway
        gateway.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    private func handle(_ event: GatewayEvent) {
        switch event.name {
        case "heartbeat":
            lastHeartbeat = .now
            heartbeatCount += 1
            push(&heartbeatTimes, .now)
            push(&cognition, entry("waveform.path.ecg", "HEARTBEAT TICK", nil))
        case "cron":
            push(&actionLog, entry("clock.arrow.circlepath", "Scheduled job",
                                   event.payload["name"]?.stringValue ?? event.payload["id"]?.stringValue))
        case "presence":
            push(&actionLog, entry("dot.radiowaves.left.and.right", "Presence update", nil))
        case "exec.approval.requested":
            push(&actionLog, entry("exclamationmark.shield", "Exec approval requested",
                                   event.payload["command"]?.stringValue))
        case "athena.connected":
            push(&actionLog, entry("bolt.horizontal", "Connected to gateway", nil))
        case "athena.reconnecting":
            push(&actionLog, entry("arrow.triangle.2.circlepath", "Reconnecting…",
                                   "attempt \(event.payload["attempt"]?.intValue ?? 0)"))
        case "chat", "agent":
            if let tool = event.payload["tool"]?.stringValue ?? event.payload["toolName"]?.stringValue {
                push(&cognition, entry("wrench.and.screwdriver", "Tool: \(tool)", nil))
            } else if event.payload["state"]?.stringValue == "final" {
                push(&cognition, entry("checkmark.circle", "Turn complete", nil))
            } else if cognition.last?.title != "Thinking…" {
                // Collapse the streaming-event firehose into one row.
                push(&cognition, entry("brain", "Thinking…", nil))
            }
        default:
            if event.name.hasPrefix("session.tool") {
                push(&cognition, entry("wrench.and.screwdriver", "Tool call", nil))
            }
        }
    }

    private func entry(_ icon: String, _ title: String, _ detail: String?) -> ActivityEntry {
        ActivityEntry(icon: icon, title: title, detail: detail, date: .now)
    }
    private func push<T>(_ array: inout [T], _ element: T) {
        array.append(element)
        if array.count > cap { array.removeFirst(array.count - cap) }
    }
}
