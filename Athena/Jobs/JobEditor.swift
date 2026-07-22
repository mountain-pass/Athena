import SwiftUI

/// Job editor with plain-English scheduling.
/// Cron is still available under "Custom", but nobody has to touch it.
///
/// Layout note: the previous version packed the templates and the seven
/// schedule kinds into single fixed rows, which overflowed the sheet and got
/// clipped. Both now wrap into grids, and the whole body scrolls, so nothing
/// can be pushed off-screen regardless of window size.
struct JobEditor: View {
    let job: ScheduledJob?
    let onSave: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule: Schedule = .dailyAt(hour: 9, minute: 0)
    @State private var customCron = "0 9 * * *"
    @State private var didPrefill = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
            header
            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if job == nil { templateSection }
                    nameSection
                    scheduleSection
                    promptSection
                }
                .padding(22)
            }

            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 780, height: 700)
        .background(Theme.bg)
        .onAppear(perform: prefill)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(job == nil ? "New Scheduled Job" : "Edit Job")
                    .font(Theme.mono(17, weight: .bold)).foregroundStyle(Theme.text)
                Text("Runs on the gateway, on your schedule.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17)).foregroundStyle(Theme.textDim)
                    .padding(6).contentShape(Circle())
            }.buttonStyle(.plain).help("Close")
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(Theme.mono(12)).foregroundStyle(Theme.textDim)
                .padding(.horizontal, 14).padding(.vertical, 9)

            Spacer()

            if !isValid {
                Text(name.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Give the job a name"
                     : "Tell Athena what to do")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
            }

            Button {
                onSave(name.trimmingCharacters(in: .whitespaces),
                       schedule.cron,
                       prompt.trimmingCharacters(in: .whitespaces))
                dismiss()
            } label: {
                Text(job == nil ? "CREATE JOB" : "SAVE CHANGES")
                    .font(Theme.label).kerning(1)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(isValid ? Theme.amber : Theme.panelAlt)
                    .foregroundStyle(isValid ? .black : Theme.textFaint)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!isValid)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    // MARK: Sections

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Start from a template")
            // Two columns wrap cleanly instead of overflowing a single row.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(Self.templates.enumerated()), id: \.offset) { _, t in
                    Button {
                        name = t.title
                        prompt = t.prompt
                        schedule = t.schedule
                        customCron = t.schedule.cron
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: t.icon)
                                .font(.system(size: 14)).foregroundStyle(Theme.amber)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title)
                                    .font(Theme.mono(12, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(t.schedule.summary)
                                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panelAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Job name")
            TextField("e.g. Morning briefing", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.mono(13)).foregroundStyle(Theme.text)
                .padding(11)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "When should it run?")

            // A menu picker instead of a 7-segment control — the segmented
            // version was wider than the sheet and the last option was cut off.
            HStack(spacing: 12) {
                Picker("", selection: Binding(
                    get: { schedule.kind },
                    set: { schedule = schedule.changing(to: $0) })) {
                    ForEach(Schedule.Kind.allCases) { k in Text(k.rawValue).tag(k) }
                }
                .labelsHidden()
                .frame(width: 220)

                detailControls
                Spacer(minLength: 0)
            }

            // Live confirmation of what was actually built.
            HStack(spacing: 10) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.green)
                Text(schedule.summary)
                    .font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.green)
                Text(schedule.cron)
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var detailControls: some View {
        switch schedule.kind {
        case .everyNHours:
            Stepper("Every \(schedule.interval) hour\(schedule.interval == 1 ? "" : "s")",
                    value: Binding(get: { schedule.interval },
                                   set: { schedule = .everyNHours($0) }),
                    in: 1...23)
                .font(Theme.mono(12)).foregroundStyle(Theme.text)

        case .everyNMinutes:
            Stepper("Every \(schedule.interval) minutes",
                    value: Binding(get: { schedule.interval },
                                   set: { schedule = .everyNMinutes($0) }),
                    in: 5...59, step: 5)
                .font(Theme.mono(12)).foregroundStyle(Theme.text)

        case .dailyAt, .weekdaysAt:
            timePickers { h, m in
                schedule.kind == .dailyAt
                    ? .dailyAt(hour: h, minute: m)
                    : .weekdaysAt(hour: h, minute: m)
            }

        case .weeklyOn:
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { schedule.weekday },
                    set: { schedule = .weeklyOn(weekday: $0, hour: schedule.hour,
                                                minute: schedule.minute) })) {
                    ForEach(0..<7, id: \.self) { d in Text(Schedule.weekdayNames[d]).tag(d) }
                }
                .labelsHidden().frame(width: 120)
                timePickers { h, m in
                    .weeklyOn(weekday: schedule.weekday, hour: h, minute: m)
                }
            }

        case .monthlyOn:
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { schedule.monthDay },
                    set: { schedule = .monthlyOn(day: $0, hour: schedule.hour,
                                                 minute: schedule.minute) })) {
                    ForEach(1...28, id: \.self) { d in Text("Day \(d)").tag(d) }
                }
                .labelsHidden().frame(width: 100)
                timePickers { h, m in
                    .monthlyOn(day: schedule.monthDay, hour: h, minute: m)
                }
            }

        case .custom:
            TextField("0 9 * * *", text: $customCron)
                .textFieldStyle(.plain)
                .font(Theme.mono(12)).foregroundStyle(Theme.text)
                .padding(9)
                .frame(width: 170)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
                .onChange(of: customCron) { _, new in schedule = .custom(new) }
        }
    }

    /// Hour + minute pickers, shared by every time-of-day schedule kind.
    @ViewBuilder
    private func timePickers(_ build: @escaping (Int, Int) -> Schedule) -> some View {
        HStack(spacing: 6) {
            Text("at").font(Theme.mono(11)).foregroundStyle(Theme.textDim)
            Picker("", selection: Binding(
                get: { schedule.hour },
                set: { schedule = build($0, schedule.minute) })) {
                ForEach(0..<24, id: \.self) { h in Text(Self.hourLabel(h)).tag(h) }
            }
            .labelsHidden().frame(width: 90)
            Picker("", selection: Binding(
                get: { schedule.minute },
                set: { schedule = build(schedule.hour, $0) })) {
                ForEach([0, 15, 30, 45], id: \.self) { m in Text(String(format: ":%02d", m)).tag(m) }
            }
            .labelsHidden().frame(width: 70)
        }
    }

    private static func hourLabel(_ h: Int) -> String {
        let suffix = h < 12 ? "am" : "pm"
        let display = h % 12 == 0 ? 12 : h % 12
        return "\(display) \(suffix)"
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "What should Athena do?")
                Spacer()
                Text("\(prompt.count) characters")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
            }

            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Write it as if you were asking her directly — \"Check my monitored feeds and tell me anything important that happened overnight.\"")
                        .font(Theme.mono(12)).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            Text("Tip: for background jobs you don't want to be pinged about, end with \"reply HEARTBEAT_OK\" so Athena stays quiet unless something needs you.")
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let job else { return }
        name = job.name
        prompt = job.prompt
        schedule = Schedule.from(cron: job.scheduleExpr)
        customCron = job.scheduleExpr
    }
}
