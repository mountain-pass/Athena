import SwiftUI
import AppKit

/// Chat input backed by NSTextView so we get precise key handling:
///   • Return          → send
///   • Shift+Return    → newline (keep typing)
///   • Option+Return   → newline (alternative, matches many chat apps)
/// It also grows with content up to `maxHeight`, then scrolls.
struct MultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var minHeight: CGFloat = 20
    var maxHeight: CGFloat = 140
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13 * Theme.uiScale, weight: .regular)
        textView.textColor = NSColor(Theme.text)
        textView.insertionPointColor = NSColor(Theme.amber)
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: MultilineTextInput
        weak var textView: NSTextView?

        init(_ parent: MultilineTextInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        /// Intercepts Return before the text view inserts a newline.
        func textView(_ textView: NSTextView,
                      doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true      // we handled it either way

            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true

            default:
                return false
            }
        }

        func recalculateHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let target = min(max(used + 8, parent.minHeight), parent.maxHeight)
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { self.parent.height = target }
            }
        }
    }
}
