import SwiftUI

/// Task detail: notes, agent progress timeline, and questions awaiting answers.
struct TodoDetailSheet: View {
    let item: TodoItem
    @ObservedObject var todos: TodoStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var owner: TodoItem.Owner = .me
    @State private var answers: [String: String] = [:]
    @State private var confirmDelete = false

    /// Always read through the store so agent updates appear live.
    private var live: TodoItem {
        todos.items.first { $0.id == item.id } ?? item
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleSection
                    if live.owner == .athena { agentSection }
                    notesSection
                }
                .padding(18)
            }

            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 560, height: 620)
        .background(Theme.bg)
        .onAppear {
            title = live.title
            notes = live.notes
            owner = live.owner
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                todos.toggleDone(live)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: live.done ? "checkmark.circle.fill" : "circle")
                    Text(live.done ? "Completed" : "Mark complete")
                        .font(Theme.mono(11, weight: .medium))
                }
                .foregroundStyle(live.done ? Theme.green : Theme.textDim)
            }
            .buttonStyle(.plain)

            Spacer()

            if live.owner == .athena {
                HStack(spacing: 5) {
                    if todos.runningTasks.contains(live.id) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Circle().fill(live.status.tint).frame(width: 5, height: 5)
                    }
                    Text(live.status.label).font(Theme.mono(10))
                        .foregroundStyle(live.status.tint)
                }
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15)).foregroundStyle(Theme.textDim)
            }.buttonStyle(.plain)
        }
        .padding(16)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Task", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.mono(16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1...3)

            HStack(spacing: 8) {
                ForEach(TodoItem.Owner.allCases, id: \.self) { candidate in
                    Button {
                        withAnimation(.spring(duration: 0.2)) { owner = candidate }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: candidate.icon).font(.system(size: 9))
                            Text(candidate == .me ? "Mine" : "Delegated to Athena")
                                .font(Theme.mono(10))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(owner == candidate
                                    ? candidate.tint.opacity(0.18) : Theme.panelAlt)
                        .clipShape(Capsule())
                        .foregroundStyle(owner == candidate ? candidate.tint : Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("created \(live.createdAt, format: .dateTime.day().month().hour().minute())")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    @ViewBuilder private var agentSection: some View {
        // Questions first — they're blocking.
        if !live.openQuestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.red)
                    SectionLabel(text: "Athena needs an answer", color: Theme.red)
                }
                ForEach(live.openQuestions) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.text)
                            .font(Theme.mono(11)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            TextField("Your answer…",
                                      text: Binding(
                                        get: { answers[question.id] ?? "" },
                                        set: { answers[question.id] = $0 }))
                                .textFieldStyle(.plain).font(Theme.mono(11))
                                .padding(7).background(Theme.bg)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onSubmit { submit(question) }
                            Button("REPLY") { submit(question) }
                                .buttonStyle(.plain).font(Theme.label).kerning(1)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Theme.amber).clipShape(Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(10)
                    .background(Theme.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }

        // Progress timeline
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Progress")
                Spacer()
                if let percent = live.percent {
                    Text("\(percent)%").font(Theme.mono(10, weight: .medium))
                        .foregroundStyle(Theme.amber)
                }
                Button {
                    todos.nudge(live)
                } label: {
                    Label("Nudge", systemImage: "bolt.fill")
                        .font(Theme.mono(9)).foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
                .help("Ask Athena to continue this task now")
                Button {
                    Task { await todos.pullAgentUpdates() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9)).foregroundStyle(Theme.textDim)
                }.buttonStyle(.plain)
            }

            if live.progress.isEmpty {
                Text(todos.runningTasks.contains(live.id)
                     ? "Athena is working on this now. You can close this window — it keeps running in the background."
                     : "No updates yet. Athena logs progress as it works.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(live.progress.reversed()) { note in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        Circle().fill(Theme.amber).frame(width: 5, height: 5)
                        Rectangle().fill(Theme.border).frame(width: 1)
                    }
                    .frame(height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.text)
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(note.at, format: .dateTime.hour().minute())
                            .font(Theme.mono(8)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            // Answered questions, for the record
            let answered = live.questions.filter { $0.answer != nil }
            if !answered.isEmpty {
                Divider().overlay(Theme.border).padding(.vertical, 4)
                SectionLabel(text: "Answered")
                ForEach(answered) { question in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Q: \(question.text)")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                        Text("A: \(question.answer ?? "")")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Notes / context for Athena")
            TextEditor(text: $notes)
                .font(Theme.mono(11))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 90)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack {
            Button {
                if confirmDelete { todos.delete(live); dismiss() }
                else { withAnimation { confirmDelete = true } }
            } label: {
                Label(confirmDelete ? "Tap again to delete" : "Delete",
                      systemImage: "trash")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.red)
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Save") {
                var updated = live
                updated.title = title
                updated.notes = notes
                let wasDelegated = updated.owner == .athena
                updated.owner = owner
                todos.update(updated)
                // Newly delegated → brief the agent.
                if owner == .athena && !wasDelegated {
                    todos.delegate(updated)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func submit(_ question: AgentQuestion) {
        let reply = (answers[question.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !reply.isEmpty else { return }
        todos.answer(question: question, on: live, with: reply)
        answers[question.id] = ""
    }
}
