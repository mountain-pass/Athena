import SwiftUI

/// Scheduled jobs manager — create and control OpenClaw cron jobs natively,
/// and see what they actually did when they ran.
struct JobsView: View {
    @ObservedObject var jobs: JobsStore
    @State private var showEditor = false
    @State private var editing: ScheduledJob?
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let err = jobs.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.mono(11)).foregroundStyle(Theme.red)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }

            Divider().overlay(Theme.border)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if jobs.jobs.isEmpty {
                        emptyState
                    }
                    ForEach(jobs.jobs) { job in
                        JobCard(
                            job: job,
                            status: jobs.actionStatus[job.id],
                            runs: jobs.runs(for: job.id),
                            expanded: expanded.contains(job.id),
                            onToggleExpand: {
                                if expanded.contains(job.id) { expanded.remove(job.id) }
                                else { expanded.insert(job.id) }
                            },
                            onToggle: { jobs.toggle(job) },
                            onRun: { jobs.runNow(job) },
                            onEdit: { editing = job; showEditor = true },
                            onDelete: { jobs.delete(job) })
                    }
                }
                .padding(20)
            }
        }
        .panel()
        .onAppear { jobs.refresh() }
        .sheet(isPresented: $showEditor) {
            JobEditor(job: editing) { name, expr, prompt in
                if let editing {
                    var j = editing; j.name = name; j.scheduleExpr = expr; j.prompt = prompt
                    jobs.update(j)
                } else {
                    jobs.create(name: name, scheduleExpr: expr, prompt: prompt)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Automation / Scheduled Jobs", color: Theme.amber)
                Text("Athena runs these on the gateway — they fire even while this Mac sleeps.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if jobs.loading {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            }
            Button { jobs.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
                    .padding(7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Refresh from the gateway")

            Button {
                editing = nil; showEditor = true
            } label: {
                Label("NEW JOB", systemImage: "plus")
                    .font(Theme.label).kerning(1)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.black)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 30)).foregroundStyle(Theme.textFaint)
            Text("No scheduled jobs yet")
                .font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.textDim)
            Text("Create one to have Athena do something on a schedule — a morning briefing, a news sweep, a weekly review.")
                .font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Job card

private struct JobCard: View {
    let job: ScheduledJob
    let status: String?
    let runs: [JobRun]
    let expanded: Bool
    let onToggleExpand: () -> Void
    let onToggle: () -> Void
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            if expanded { historySection }
        }
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(job.running ? Theme.green.opacity(0.5) : Theme.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.18), value: expanded)
        .animation(.easeInOut(duration: 0.18), value: job.running)
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: .init(get: { job.enabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch).tint(Theme.green).labelsHidden()
                .help(job.enabled ? "Pause this job" : "Resume this job")
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(job.name)
                        .font(Theme.mono(14, weight: .semibold))
                        .foregroundStyle(job.enabled ? Theme.text : Theme.textDim)
                    if job.running { runningBadge }
                    if !job.enabled { pausedBadge }
                }

                // Schedule in plain English; cron kept as a quiet detail.
                HStack(spacing: 10) {
                    Label(Schedule.from(cron: job.scheduleExpr).summary, systemImage: "clock")
                        .font(Theme.mono(11)).foregroundStyle(Theme.amber)
                    Text(job.scheduleExpr)
                        .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                }

                Text(job.prompt)
                    .font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    if let last = job.lastRun {
                        Label("Last run \(Self.relative(last))", systemImage: "checkmark.circle")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    }
                    if let next = job.nextRun, job.enabled {
                        Label("Next \(Self.relative(next))", systemImage: "arrow.right.circle")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    } else if !job.enabled {
                        Label("Paused — no further runs scheduled", systemImage: "pause.circle")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    }
                    if !runs.isEmpty {
                        Button(action: onToggleExpand) {
                            Label("\(runs.count) run\(runs.count == 1 ? "" : "s")",
                                  systemImage: expanded ? "chevron.down" : "chevron.right")
                                .font(Theme.mono(10)).foregroundStyle(Theme.amber)
                        }.buttonStyle(.plain)
                    }
                }

                if let status {
                    Text(status)
                        .font(Theme.mono(10))
                        .foregroundStyle(status.lowercased().contains("fail")
                                         ? Theme.red : Theme.green)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 8)

            actionButtons
        }
        .padding(14)
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            // Labelled, because an unlabelled play icon didn't say what it did.
            Button(action: onRun) {
                Label("RUN NOW", systemImage: "play.fill")
                    .font(Theme.mono(9, weight: .semibold)).kerning(0.5)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.green.opacity(0.15))
                    .foregroundStyle(Theme.green)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(job.running)
            .help("Trigger this job on the gateway right now, without waiting for its schedule")

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    .padding(7).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Edit")

            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12)).foregroundStyle(Theme.red.opacity(0.8))
                    .padding(7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Delete")
            .confirmationDialog("Delete \(job.name)?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete job", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the schedule from the gateway. It can't be undone.")
            }
        }
    }

    private var runningBadge: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini).scaleEffect(0.7)
            Text("RUNNING").font(Theme.mono(9, weight: .semibold)).kerning(0.5)
        }
        .foregroundStyle(Theme.green)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.green.opacity(0.12)).clipShape(Capsule())
    }

    private var pausedBadge: some View {
        Label("PAUSED", systemImage: "pause.fill")
            .font(Theme.mono(9, weight: .semibold)).kerning(0.5)
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.panel).clipShape(Capsule())
            .help("Still saved on the gateway — it just won't fire until you switch it back on")
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Run history")
                    .padding(.bottom, 2)
                ForEach(runs) { run in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: run.outcome))
                            .font(.system(size: 10))
                            .foregroundStyle(color(for: run.outcome))
                            .frame(width: 14)
                        Text(Self.timestamp(run.startedAt))
                            .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                            .frame(width: 140, alignment: .leading)
                        Text(run.duration.map { String(format: "%.1fs", $0) } ?? "—")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .frame(width: 50, alignment: .leading)
                        Text(run.detail ?? run.outcome.rawValue)
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                Text("History is recorded while Athena is connected — runs that happen with the app closed appear only as \"last run\".")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                    .padding(.top, 4)
            }
            .padding(14)
        }
    }

    private func icon(for outcome: JobRun.Outcome) -> String {
        switch outcome {
        case .running:   return "circle.dotted"
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    private func color(for outcome: JobRun.Outcome) -> Color {
        switch outcome {
        case .running:   return Theme.amber
        case .succeeded: return Theme.green
        case .failed:    return Theme.red
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: .now)
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, h:mm:ss a"
        return f.string(from: date)
    }
}
