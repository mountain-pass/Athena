import SwiftUI

/// Todo list panel — sits under the voice orb in the left column.
struct TodoPanel: View {
    @ObservedObject var todos: TodoStore

    @State private var draft = ""
    @State private var draftOwner: TodoItem.Owner = .me
    @State private var selected: TodoItem?
    @State private var showCompleted = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // Composer
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Add a task…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text)
                        .focused($inputFocused)
                        .onSubmit(commit)
                    Button(action: commit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(draft.isEmpty ? Theme.textFaint : draftOwner.tint)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
                .background(Theme.bg.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Owner switch — short labels so they never wrap.
                HStack(spacing: 4) {
                    ForEach(TodoItem.Owner.allCases, id: \.self) { owner in
                        Button {
                            withAnimation(.spring(duration: 0.2)) { draftOwner = owner }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: owner.icon).font(.system(size: 8))
                                Text(owner == .me ? "Me" : "Athena")
                                    .font(Theme.mono(9))
                                    .fixedSize()
                            }
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(draftOwner == owner
                                        ? owner.tint.opacity(0.18) : Theme.panelAlt)
                            .clipShape(Capsule())
                            .foregroundStyle(draftOwner == owner ? owner.tint : Theme.textFaint)
                        }
                        .buttonStyle(.plain)
                        .help(owner == .me ? "Keep this task for yourself"
                                           : "Delegate to Athena — it starts immediately")
                    }
                    Spacer()
                }
            }

            // List
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(todos.sorted) { item in
                        TodoRow(item: item,
                                running: todos.runningTasks.contains(item.id),
                                onToggle: { todos.toggleDone(item) },
                                onOpen: { selected = item })
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity)
                                    .combined(with: .move(edge: .top)),
                                removal: .scale(scale: 0.85).combined(with: .opacity)))
                    }

                    if !todos.completed.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { showCompleted.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 7))
                                Text("\(todos.completed.count) completed")
                                    .font(Theme.mono(9))
                                Spacer()
                                if showCompleted {
                                    Button("Clear") { todos.clearCompleted() }
                                        .font(Theme.mono(9)).foregroundStyle(Theme.red)
                                        .buttonStyle(.plain)
                                }
                            }
                            .foregroundStyle(Theme.textFaint)
                            .padding(.top, 4)
                        }
                        .buttonStyle(.plain)

                        if showCompleted {
                            ForEach(todos.completed) { item in
                                TodoRow(item: item,
                                        running: false,
                                        onToggle: { todos.toggleDone(item) },
                                        onOpen: { selected = item })
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: .infinity)   // fill the rest of the column
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .panel()
        .sheet(item: $selected) { item in
            TodoDetailSheet(item: item, todos: todos)
        }
        .task { todos.startSync() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Todo", color: Theme.amber)
            if todos.attentionCount > 0 {
                Text("\(todos.attentionCount)")
                    .font(Theme.mono(8, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.red).clipShape(Capsule())
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            if todos.syncing {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Text("\(todos.sorted.count) open")
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
        }
    }

    private func commit() {
        todos.add(title: draft, owner: draftOwner)
        draft = ""
        inputFocused = true
    }
}

// MARK: - Row

private struct TodoRow: View {
    let item: TodoItem
    let running: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false
    @State private var checkScale: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Animated checkbox
            Button {
                checkScale = 0.6
                withAnimation(.spring(duration: 0.3, bounce: 0.5)) { checkScale = 1 }
                onToggle()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.done ? Theme.green : Theme.border, lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if item.done {
                        Circle().fill(Theme.green.opacity(0.2)).frame(width: 15, height: 15)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(checkScale)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(item.done ? Theme.textFaint : Theme.text)
                    .strikethrough(item.done, color: Theme.textFaint)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.2), value: item.done)

                if !item.done {
                    // Compact icon strip — no wrapping text chips.
                    HStack(spacing: 9) {
                        Image(systemName: item.owner.icon)
                            .font(.system(size: 9))
                            .foregroundStyle(item.owner.tint)
                            .help(item.owner == .me ? "Yours" : "Delegated to Athena")

                        if item.owner == .athena {
                            HStack(spacing: 3) {
                                if running {
                                    ProgressView().controlSize(.small).scaleEffect(0.4)
                                        .frame(width: 9, height: 9)
                                } else {
                                    Image(systemName: item.status.icon)
                                        .font(.system(size: 9))
                                }
                                Text(item.status.shortLabel)
                                    .font(Theme.mono(8.5))
                                    .fixedSize()
                            }
                            .foregroundStyle(item.status.tint)
                        }

                        if !item.openQuestions.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.system(size: 9))
                                Text("\(item.openQuestions.count)")
                                    .font(Theme.mono(8.5))
                            }
                            .foregroundStyle(Theme.red)
                            .help("\(item.openQuestions.count) question(s) waiting")
                        }

                        if item.hasResult {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.green)
                                .help("Result ready — click to read")
                        }

                        Spacer(minLength: 0)

                        if let percent = item.percent, percent > 0, percent < 100 {
                            Text("\(percent)%")
                                .font(Theme.mono(8.5)).foregroundStyle(Theme.textFaint)
                        }
                    }

                    // Slim progress bar, only while in flight.
                    if let percent = item.percent, percent > 0, percent < 100 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.border).frame(height: 2)
                                Capsule().fill(Theme.amber)
                                    .frame(width: geo.size.width * CGFloat(percent) / 100,
                                           height: 2)
                                    .animation(.easeOut(duration: 0.5), value: percent)
                            }
                        }
                        .frame(height: 2)
                    }
                }
            }

            Spacer(minLength: 0)

            if hovering && !item.done {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(9)
        .background(item.needsAttention && !item.done
                    ? Theme.red.opacity(0.07)
                    : (hovering ? Theme.panelAlt : Theme.panelAlt.opacity(0.55)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.needsAttention && !item.done
                        ? Theme.red.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .opacity(item.done ? 0.55 : 1)
    }
}
