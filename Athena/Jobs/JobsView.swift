import SwiftUI

/// Scheduled jobs manager — create and control OpenClaw cron jobs natively.
struct JobsView: View {
    @ObservedObject var jobs: JobsStore
    @State private var showEditor = false
    @State private var editing: ScheduledJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Automation / Scheduled Jobs", color: Theme.amber)
                    Text("Runs on the gateway — even while this Mac sleeps.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button {
                    editing = nil; showEditor = true
                } label: {
                    Label("NEW JOB", systemImage: "plus")
                        .font(Theme.label).kerning(1)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.amber).clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.black)
                }.buttonStyle(.plain)
                Button { jobs.refresh() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }
            .padding(16)

            if let err = jobs.errorMessage {
                Text(err).font(Theme.mono(11)).foregroundStyle(Theme.red).padding(.horizontal, 16)
            }

            ScrollView {
                VStack(spacing: 8) {
                    if jobs.jobs.isEmpty && !jobs.loading {
                        Text("No scheduled jobs yet. Create one, or save a News brief schedule.")
                            .font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
                            .padding(.top, 40)
                    }
                    ForEach(jobs.jobs) { job in
                        JobRow(job: job,
                               onToggle: { jobs.toggle(job) },
                               onRun: { jobs.runNow(job) },
                               onEdit: { editing = job; showEditor = true },
                               onDelete: { jobs.delete(job) })
                    }
                }
                .padding(.horizontal, 16)
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
}

private struct JobRow: View {
    let job: ScheduledJob
    let onToggle: () -> Void
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: .init(get: { job.enabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch).tint(Theme.green).labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    // Plain English, with the cron kept as a quiet detail.
                    Label(Schedule.from(cron: job.scheduleExpr).summary, systemImage: "clock")
                        .font(Theme.mono(10)).foregroundStyle(Theme.amber)
                    Text(job.prompt).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { onRun() } label: {
                Image(systemName: "play.circle").foregroundStyle(Theme.green)
            }.buttonStyle(.plain).help("Run now")
            Button { onEdit() } label: {
                Image(systemName: "pencil").foregroundStyle(Theme.textDim)
            }.buttonStyle(.plain)
            Button { onDelete() } label: {
                Image(systemName: "trash").foregroundStyle(Theme.red.opacity(0.8))
            }.buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

