import SwiftUI

/// Roomy job editor with plain-English scheduling.
/// Cron is still available under "Custom", but nobody has to touch it.
struct JobEditor: View {
    let job: ScheduledJob?
    let onSave: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule: Schedule = .dailyAt(hour: 9, minute: 0)
    @State private var customCron = "0 9 * * *"

    /// Ready-made jobs for people who don't know what to ask for.
    private static let templates: [(title: String, icon: String, schedule: Schedule, prompt: String)] = [
        ("Morning briefing", "sun.horizon", .dailyAt(hour: 7, minute: 0),
         "Give me a short briefing for the day: anything urgent in my news archive, plus what's on my calendar if you can see it. Keep it under 200 words."),
        ("Evening wrap-up", "moon.stars", .dailyAt(hour: 18, minute: 0),
         "Summarize what happened today across my monitored topics. Lead with anything that actually matters. Keep it brief."),
        ("News sweep", "antenna.radiowaves.left.and.right", .everyNHours(6),
         "Fetch my monitored news feeds and append anything new to the news archive. Don't message me — reply HEARTBEAT_OK."),
        ("Weekly review", "calendar", .weeklyOn(weekday: 1, hour: 9, minute: 0),
         "Review the past week from your memory and archives. What were the big themes? What should I be paying attention to this week?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(job == nil ? "New Scheduled Job" : "Edit Job")
                    .font(Theme.mono(17, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }
            .padding(18)

            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if job == nil { templateRow }

                    // Name
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Job name")
                        TextField("e.g. Morning briefing", text: $name)
                            .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.text)
                            .padding(10).background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Schedule
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "When should it run?")
                        scheduleBuilder
                        HStack(spacing: 8) {
                            Image(systemName: "clock.badge.checkmark").foregroundStyle(Theme.green)
                            Text(schedule.summary)
                                .font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.text)
                            Text("· \(schedule.cron)")
                                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Instructions — the big one
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            SectionLabel(text: "What should Athena do?")
                            Spacer()
                            Text("\(prompt.count) characters")
                                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                        }
                        TextEditor(text: $prompt)
                            .font(Theme.mono(12))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 220)
                            .background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        Text("Write it like you'd say it out loud. Add “don't message me — reply HEARTBEAT_OK” for silent background jobs.")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    }
                }
                .padding(18)
            }

            Divider().overlay(Theme.border)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.textDim)
                Spacer()
                Button {
                    onSave(name, schedule.cron, prompt)
                    dismiss()
                } label: {
                    Text(job == nil ? "CREATE JOB" : "SAVE CHANGES")
                        .font(Theme.label).kerning(1)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(canSave ? Theme.amber : Theme.panelAlt)
                        .clipShape(Capsule())
                        .foregroundStyle(canSave ? .black : Theme.textFaint)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(18)
        }
        .frame(width: 720, height: 720)
        .background(Theme.bg)
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        guard let job else { return }
        name = job.name
        prompt = job.prompt
        schedule = Schedule.from(cron: job.scheduleExpr)
        customCron = job.scheduleExpr
    }

    // MARK: Templates

    private var templateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Start from a template")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.templates, id: \.title) { template in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                name = template.title
                                prompt = template.prompt
                                schedule = template.schedule
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: template.icon).foregroundStyle(Theme.amber)
                                Text(template.title)
                                    .font(Theme.mono(11, weight: .medium)).foregroundStyle(Theme.text)
                                Text(template.schedule.summary)
                                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                            }
                            .padding(10)
                            .frame(width: 150, alignment: .leading)
                            .background(Theme.panelAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Schedule builder

    @ViewBuilder private var scheduleBuilder: some View {
        Picker("", selection: Binding(
            get: { schedule.kind },
            set: { schedule = schedule.changing(to: $0) })) {
            ForEach(Schedule.Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        HStack(spacing: 10) {
            switch schedule.kind {
            case .everyNHours:
                Text("Every").font(Theme.body).foregroundStyle(Theme.textDim)
                Picker("", selection: Binding(
                    get: { schedule.interval },
                    set: { schedule = .everyNHours($0) })) {
                    ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 70)
                Text("hours").font(Theme.body).foregroundStyle(Theme.textDim)

            case .everyNMinutes:
                Text("Every").font(Theme.body).foregroundStyle(Theme.textDim)
                Picker("", selection: Binding(
                    get: { schedule.interval },
                    set: { schedule = .everyNMinutes($0) })) {
                    ForEach([5, 10, 15, 20, 30, 45], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 70)
                Text("minutes").font(Theme.body).foregroundStyle(Theme.textDim)

            case .dailyAt, .weekdaysAt:
                Text(schedule.kind == .dailyAt ? "Every day at" : "Weekdays at")
                    .font(Theme.body).foregroundStyle(Theme.textDim)
                timePickers { h, m in
                    schedule = schedule.kind == .dailyAt
                        ? .dailyAt(hour: h, minute: m)
                        : .weekdaysAt(hour: h, minute: m)
                }

            case .weeklyOn:
                Text("Every").font(Theme.body).foregroundStyle(Theme.textDim)
                Picker("", selection: Binding(
                    get: { schedule.weekday },
                    set: { schedule = .weeklyOn(weekday: $0, hour: schedule.hour,
                                                minute: schedule.minute) })) {
                    ForEach(0..<7, id: \.self) { Text(Schedule.weekdayNames[$0]).tag($0) }
                }
                .labelsHidden().frame(width: 120)
                Text("at").font(Theme.body).foregroundStyle(Theme.textDim)
                timePickers { h, m in
                    schedule = .weeklyOn(weekday: schedule.weekday, hour: h, minute: m)
                }

            case .monthlyOn:
                Text("Day").font(Theme.body).foregroundStyle(Theme.textDim)
                Picker("", selection: Binding(
                    get: { schedule.monthDay },
                    set: { schedule = .monthlyOn(day: $0, hour: schedule.hour,
                                                 minute: schedule.minute) })) {
                    ForEach(1...28, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 70)
                Text("at").font(Theme.body).foregroundStyle(Theme.textDim)
                timePickers { h, m in
                    schedule = .monthlyOn(day: schedule.monthDay, hour: h, minute: m)
                }

            case .custom:
                TextField("0 9 * * *", text: $customCron)
                    .textFieldStyle(.plain).font(Theme.mono(12))
                    .padding(8).background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .frame(width: 160)
                    .onChange(of: customCron) { _, new in schedule = .custom(new) }
                Text("minute hour day month weekday")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func timePickers(_ apply: @escaping (Int, Int) -> Void) -> some View {
        Picker("", selection: Binding(
            get: { schedule.hour },
            set: { apply($0, schedule.minute) })) {
            ForEach(0..<24, id: \.self) { h in
                Text(hourLabel(h)).tag(h)
            }
        }
        .labelsHidden().frame(width: 100)

        Picker("", selection: Binding(
            get: { schedule.minute },
            set: { apply(schedule.hour, $0) })) {
            ForEach([0, 15, 30, 45], id: \.self) { m in
                Text(String(format: ":%02d", m)).tag(m)
            }
        }
        .labelsHidden().frame(width: 70)
    }

    private func hourLabel(_ h: Int) -> String {
        var comps = DateComponents(); comps.hour = h; comps.minute = 0
        let date = Calendar.current.date(from: comps) ?? .now
        let f = DateFormatter(); f.dateFormat = "h a"
        return f.string(from: date)
    }
}
