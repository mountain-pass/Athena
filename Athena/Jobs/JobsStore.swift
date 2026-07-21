import Foundation

struct ScheduledJob: Identifiable {
    let id: String
    var name: String
    var scheduleExpr: String
    var prompt: String
    var enabled: Bool
    var lastRun: String?
}

/// Manages OpenClaw cron jobs from the native UI (list / create / edit /
/// enable / run-now / delete). Jobs run on the gateway (your Mac Mini), so
/// they fire even when this laptop is asleep or in transit.
@MainActor
final class JobsStore: ObservableObject {
    @Published private(set) var jobs: [ScheduledJob] = []
    @Published private(set) var loading = false
    @Published var errorMessage: String?

    private let gateway: GatewayClient

    init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    func refresh() {
        Task {
            loading = true
            defer { loading = false }
            do {
                let rows = try await gateway.cronList()
                jobs = rows.compactMap { row in
                    guard let id = row["id"]?.stringValue else { return nil }
                    return ScheduledJob(
                        id: id,
                        name: row["name"]?.stringValue ?? id,
                        scheduleExpr: row["schedule"]?["expr"]?.stringValue
                            ?? row["schedule"]?.stringValue ?? "?",
                        prompt: row["payload"]?["message"]?.stringValue
                            ?? row["payload"]?["text"]?.stringValue ?? "",
                        enabled: row["enabled"]?.boolValue ?? true,
                        lastRun: row["lastRunAt"]?.stringValue
                    )
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func create(name: String, scheduleExpr: String, prompt: String) {
        Task {
            do {
                _ = try await gateway.cronAdd(name: name, schedule: scheduleExpr, prompt: prompt)
                refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func update(_ job: ScheduledJob) {
        Task {
            do {
                _ = try await gateway.cronUpdate(id: job.id, patch: GatewayClient.cronPatch(
                    name: job.name, schedule: job.scheduleExpr,
                    prompt: job.prompt, enabled: job.enabled))
                refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func toggle(_ job: ScheduledJob) {
        var j = job; j.enabled.toggle(); update(j)
    }

    func runNow(_ job: ScheduledJob) {
        Task {
            do { try await gateway.cronRunNow(id: job.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func delete(_ job: ScheduledJob) {
        Task {
            do { try await gateway.cronRemove(id: job.id); refresh() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
