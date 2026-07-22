import Foundation
import Combine

struct ScheduledJob: Identifiable {
    let id: String
    var name: String
    var scheduleExpr: String
    var prompt: String
    var enabled: Bool
    var lastRun: Date?
    var nextRun: Date?
    /// Set while the gateway reports this job's run in flight.
    var running: Bool = false
}

/// One execution of a job, assembled from gateway `cron` / `task` events.
struct JobRun: Identifiable, Codable {
    enum Outcome: String, Codable { case running, succeeded, failed }
    var id: String              // runId
    var jobId: String
    var startedAt: Date
    var endedAt: Date?
    var outcome: Outcome
    var detail: String?

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

/// Manages OpenClaw cron jobs from the native UI (list / create / edit /
/// enable / run-now / delete) and keeps a local history of their runs.
///
/// Jobs execute on the gateway (the always-on Mac Mini), so they fire even
/// when this laptop is asleep. The gateway exposes no run-history RPC, so we
/// assemble history from the `cron` and `task` events it pushes while we're
/// connected, and persist it locally so it survives relaunches.
@MainActor
final class JobsStore: ObservableObject {
    @Published private(set) var jobs: [ScheduledJob] = []
    @Published private(set) var loading = false
    @Published var errorMessage: String?
    /// Per-job transient status shown in the UI ("Started…", "Failed: …").
    @Published private(set) var actionStatus: [String: String] = [:]
    /// Newest-first run history, keyed by job id.
    @Published private(set) var history: [String: [JobRun]] = [:]

    private let gateway: GatewayClient
    private var cancellables = Set<AnyCancellable>()
    /// Session key of each job's in-flight run, learned from `task` events.
    /// Needed to abort a run that's already executing.
    private var runningSessionKeys: [String: String] = [:]
    private static let historyKey = "jobs.runHistory"
    private static let maxRunsPerJob = 25

    init(gateway: GatewayClient) {
        self.gateway = gateway
        loadHistory()
        observeGateway()
    }

    // MARK: Listing

    func refresh() {
        Task {
            loading = true
            defer { loading = false }
            do {
                let rows = try await gateway.cronList()
                let running = Set(jobs.filter(\.running).map(\.id))
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
                        lastRun: Self.date(from: row["lastRunAt"] ?? row["lastRunMs"]),
                        nextRun: Self.date(from: row["nextRunAt"] ?? row["nextRunMs"]),
                        running: running.contains(id))
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Gateway timestamps arrive as epoch millis or ISO strings depending on field.
    private static func date(from value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let ms = value.doubleValue, ms > 1_000_000_000 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let s = value.stringValue {
            return ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    // MARK: Mutations

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

    /// Enable/disable — a pause, never a delete. The schedule stays on the
    /// gateway; it just stops firing until it's switched back on.
    ///
    /// Flips local state FIRST so the switch responds instantly, then sends a
    /// patch containing only `enabled`. The old version sent a full update and
    /// waited for a refresh before the UI moved, which made the toggle look
    /// broken — and any unrelated validation failure in the full patch would
    /// silently revert it.
    ///
    /// Two things beyond the patch matter here:
    /// 1. Disabling a schedule does NOT stop an execution already in flight,
    ///    so we also abort the running session.
    /// 2. We verify against the gateway afterwards. If it quietly ignored the
    ///    field, a switch that shows "off" while the job keeps firing is worse
    ///    than an error.
    func toggle(_ job: ScheduledJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        let target = !jobs[idx].enabled
        jobs[idx].enabled = target
        let wasRunning = jobs[idx].running

        Task {
            do {
                _ = try await gateway.cronUpdate(
                    id: job.id, patch: GatewayClient.cronPatch(enabled: target))

                // Pausing while a run is mid-flight: stop that run too.
                if !target, wasRunning {
                    await abortRunningExecution(job.id)
                }

                setStatus(job.id, target ? "Enabled" : "Paused — won't run until re-enabled",
                          clearAfter: 3)
                await verifyEnabledState(job.id, expected: target)
            } catch {
                // Put the switch back where it was — the change didn't take.
                if let i = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[i].enabled = !target
                }
                setStatus(job.id, "Couldn't change: \(error.localizedDescription)", clearAfter: 6)
            }
        }
    }

    /// Re-reads the job from the gateway and confirms the pause actually took.
    private func verifyEnabledState(_ jobId: String, expected: Bool) async {
        do {
            let rows = try await gateway.cronList()
            guard let row = rows.first(where: { $0["id"]?.stringValue == jobId }) else { return }
            let actual = row["enabled"]?.boolValue ?? true
            if actual != expected {
                NSLog("[jobs] gateway did not apply enabled=%@ for %@ (still %@)",
                      expected ? "true" : "false", jobId, actual ? "true" : "false")
                if let i = jobs.firstIndex(where: { $0.id == jobId }) {
                    jobs[i].enabled = actual
                }
                setStatus(jobId,
                          "The gateway didn't apply this change — the job is still \(actual ? "active" : "paused").",
                          clearAfter: 10)
            } else {
                refresh()
            }
        } catch {
            NSLog("[jobs] verify failed: %@", error.localizedDescription)
        }
    }

    /// Aborts the agent run a cron job is currently executing.
    ///
    /// Cron runs live in their own session (`agent:<agent>:cron:<jobId>`), so
    /// aborting that session is what actually stops the work — disabling the
    /// schedule alone only prevents the NEXT run.
    private func abortRunningExecution(_ jobId: String) async {
        let key = runningSessionKeys[jobId] ?? "agent:main:cron:\(jobId)"
        do {
            try await gateway.chatAbort(sessionKey: key)
            NSLog("[jobs] aborted in-flight run for %@ (session %@)", jobId, key)
            markRunning(jobId, false)
            finish(runId: "\(jobId)-aborted", jobId: jobId, outcome: .failed,
                   detail: "Stopped when the job was paused")
        } catch {
            NSLog("[jobs] could not abort run for %@: %@", jobId, error.localizedDescription)
        }
    }

    /// Triggers a run immediately. Reports what actually happened rather than
    /// firing silently — previously the play button gave no indication that
    /// anything had been sent.
    func runNow(_ job: ScheduledJob) {
        setStatus(job.id, "Starting…")
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) { jobs[idx].running = true }
        Task {
            do {
                try await gateway.cronRunNow(id: job.id)
                setStatus(job.id, "Started on the gateway", clearAfter: 4)
            } catch {
                if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[idx].running = false
                }
                setStatus(job.id, "Failed to start: \(error.localizedDescription)", clearAfter: 8)
            }
        }
    }

    func delete(_ job: ScheduledJob) {
        Task {
            do {
                try await gateway.cronRemove(id: job.id)
                history[job.id] = nil
                saveHistory()
                refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func setStatus(_ jobId: String, _ text: String, clearAfter: TimeInterval? = nil) {
        actionStatus[jobId] = text
        guard let clearAfter else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clearAfter * 1_000_000_000))
            guard let self, self.actionStatus[jobId] == text else { return }
            self.actionStatus[jobId] = nil
        }
    }

    // MARK: Run history from live events

    private func observeGateway() {
        gateway.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event.name {
                case "cron": self.ingestCronEvent(event.payload)
                case "task": self.ingestTaskEvent(event.payload)
                case "athena.connected": self.refresh()
                default: break
                }
            }
            .store(in: &cancellables)
    }

    private func ingestCronEvent(_ payload: JSONValue) {
        guard let jobId = payload["jobId"]?.stringValue else { return }
        let action = payload["action"]?.stringValue ?? ""
        let runId = payload["runId"]?.stringValue ?? "\(jobId)-\(Date().timeIntervalSince1970)"

        switch action {
        case "started":
            record(JobRun(id: runId, jobId: jobId, startedAt: .now,
                          endedAt: nil, outcome: .running, detail: nil))
            markRunning(jobId, true)
        case "finished", "completed", "succeeded":
            finish(runId: runId, jobId: jobId, outcome: .succeeded, detail: nil)
        case "failed", "error":
            finish(runId: runId, jobId: jobId, outcome: .failed,
                   detail: payload["error"]?.stringValue)
        default:
            break
        }
        refreshLastRun(jobId)
    }

    /// `task` events carry the run's terminal status for cron-kind tasks.
    private func ingestTaskEvent(_ payload: JSONValue) {
        guard let task = payload["task"],
              task["kind"]?.stringValue == "cron" else { return }
        // childSessionKey looks like "agent:main:cron:<jobId>", which is the
        // only place the job id reliably appears on these events.
        let fromKey = task["childSessionKey"]?.stringValue
            .flatMap { $0.split(separator: ":").dropFirst(3).first.map(String.init) }
        guard let jobId = fromKey ?? task["jobId"]?.stringValue else { return }
        let status = task["status"]?.stringValue ?? ""
        let runId = task["runId"]?.stringValue ?? "\(jobId)-task"
        if let key = task["childSessionKey"]?.stringValue, !key.isEmpty {
            runningSessionKeys[jobId] = key
        }

        switch status {
        case "running":
            record(JobRun(id: runId, jobId: jobId, startedAt: .now,
                          endedAt: nil, outcome: .running, detail: task["title"]?.stringValue))
            markRunning(jobId, true)
        case "completed", "done", "succeeded":
            finish(runId: runId, jobId: jobId, outcome: .succeeded, detail: nil)
        case "failed", "error":
            finish(runId: runId, jobId: jobId, outcome: .failed,
                   detail: task["error"]?.stringValue)
        default:
            break
        }
    }

    private func markRunning(_ jobId: String, _ running: Bool) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[idx].running = running
    }

    private func record(_ run: JobRun) {
        var runs = history[run.jobId] ?? []
        if let existing = runs.firstIndex(where: { $0.id == run.id }) {
            runs[existing] = run
        } else {
            runs.insert(run, at: 0)
        }
        history[run.jobId] = Array(runs.prefix(Self.maxRunsPerJob))
        saveHistory()
    }

    private func finish(runId: String, jobId: String, outcome: JobRun.Outcome, detail: String?) {
        var runs = history[jobId] ?? []
        // Match the specific run, else close out whatever is still open.
        let idx = runs.firstIndex(where: { $0.id == runId })
            ?? runs.firstIndex(where: { $0.outcome == .running })
        if let idx {
            runs[idx].endedAt = .now
            runs[idx].outcome = outcome
            runs[idx].detail = detail ?? runs[idx].detail
        } else {
            runs.insert(JobRun(id: runId, jobId: jobId, startedAt: .now,
                               endedAt: .now, outcome: outcome, detail: detail), at: 0)
        }
        history[jobId] = Array(runs.prefix(Self.maxRunsPerJob))
        markRunning(jobId, false)
        saveHistory()
        setStatus(jobId, outcome == .succeeded ? "Finished" : "Run failed", clearAfter: 5)
    }

    private func refreshLastRun(_ jobId: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[idx].lastRun = history[jobId]?.first?.startedAt ?? jobs[idx].lastRun
    }

    func runs(for jobId: String) -> [JobRun] { history[jobId] ?? [] }

    // MARK: Persistence

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let decoded = try? JSONDecoder().decode([String: [JobRun]].self, from: data)
        else { return }
        // Anything still marked running from a previous launch is stale.
        history = decoded.mapValues { runs in
            runs.map { run in
                guard run.outcome == .running else { return run }
                var r = run
                r.outcome = .failed
                r.detail = "Interrupted — app was closed"
                r.endedAt = run.startedAt
                return r
            }
        }
    }
}
