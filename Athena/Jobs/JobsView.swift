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
                    Label(job.scheduleExpr, systemImage: "clock")
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

private struct JobEditor: View {
    let job: ScheduledJob?
    let onSave: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var expr = "0 7 * * *"
    @State private var prompt = ""

    private static let presets: [(String, String)] = [
        ("Every morning 7am", "0 7 * * *"),
        ("Weekdays 9am", "0 9 * * 1-5"),
        ("Every hour", "0 * * * *"),
        ("Sunday 6pm", "0 18 * * 0"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job == nil ? "New Scheduled Job" : "Edit Job")
                .font(Theme.title).foregroundStyle(Theme.text)

            SectionLabel(text: "Name")
            TextField("e.g. Weekly portfolio summary", text: $name)
                .textFieldStyle(.roundedBorder).font(Theme.body)

            SectionLabel(text: "Schedule (cron)")
            HStack {
                TextField("0 7 * * *", text: $expr)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(width: 140)
                Picker("Preset", selection: $expr) {
                    Text("Custom").tag(expr)
                    ForEach(Self.presets, id: \.1) { p in Text(p.0).tag(p.1) }
                }
                .frame(width: 200)
            }

            SectionLabel(text: "What should the agent do?")
            TextEditor(text: $prompt)
                .font(Theme.body).frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6).background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(job == nil ? "Create" : "Save") {
                    onSave(name, expr, prompt); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || prompt.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.bg)
        .onAppear {
            if let job { name = job.name; expr = job.scheduleExpr; prompt = job.prompt }
        }
    }
}
