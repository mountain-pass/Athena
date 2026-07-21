import SwiftUI
import AppKit

/// Renders agent replies the way Claude's own apps do: markdown formatting,
/// syntax-boxed code blocks, pretty-printed JSON, and HTML with a preview
/// button — instead of a wall of raw text.
struct RichMessageView: View {
    let text: String
    @State private var blocks: [ContentBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if blocks.isEmpty {
                // Plain text while parsing (usually imperceptible).
                Text(text).font(Theme.body).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            } else {
                ForEach(blocks) { block in
                    BlockView(block: block)
                }
            }
        }
        .task(id: text) {
            // Parse off-main; big replies never stall the UI.
            let parsed = await ContentBlock.parse(text)
            withAnimation(.easeIn(duration: 0.12)) { blocks = parsed }
        }
    }
}

// MARK: - Content model

enum ContentBlock: Identifiable {
    case paragraph(AttributedString)
    case heading(String, level: Int)
    case bullet([AttributedString])
    case code(String, language: String)
    case json(String)          // pretty-printed
    case html(String)
    case divider

    var id: String {
        switch self {
        case .paragraph(let a): "p-\(String(a.characters).hashValue)"
        case .heading(let s, let l): "h\(l)-\(s.hashValue)"
        case .bullet(let items): "ul-\(items.count)-\(items.first.map { String($0.characters).hashValue } ?? 0)"
        case .code(let s, _): "code-\(s.hashValue)"
        case .json(let s): "json-\(s.hashValue)"
        case .html(let s): "html-\(s.hashValue)"
        case .divider: "hr-\(UUID().uuidString)"
        }
    }

    /// Full parse runs detached — string scanning + JSON pretty printing can
    /// be slow for large payloads.
    static func parse(_ raw: String) async -> [ContentBlock] {
        await Task.detached(priority: .userInitiated) { parseSync(raw) }.value
    }

    nonisolated static func parseSync(_ raw: String) -> [ContentBlock] {
        // Whole-message JSON? (agent returning structured data)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let pretty = prettyJSON(trimmed) {
            return [.json(pretty)]
        }

        var blocks: [ContentBlock] = []
        // Split on fenced code first.
        let segments = trimmed.components(separatedBy: "```")
        for (index, segment) in segments.enumerated() {
            if index % 2 == 1 {
                // Inside a fence: first line may be a language tag.
                var lines = segment.split(separator: "\n", omittingEmptySubsequences: false)
                let lang = lines.first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let isLangTag = !lang.isEmpty && lang.count < 12 && !lang.contains(" ")
                if isLangTag { lines = Array(lines.dropFirst()) }
                let body = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }

                if isLangTag && (lang == "json"), let pretty = prettyJSON(body) {
                    blocks.append(.json(pretty))
                } else if !isLangTag, let pretty = prettyJSON(body) {
                    blocks.append(.json(pretty))
                } else if isLangTag && (lang == "html" || lang == "htm") {
                    blocks.append(.html(body))
                } else {
                    blocks.append(.code(body, language: isLangTag ? lang : ""))
                }
            } else {
                blocks.append(contentsOf: parseMarkdownText(segment))
            }
        }
        return blocks
    }

    // MARK: markdown text → blocks

    nonisolated private static func parseMarkdownText(_ text: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var paragraph: [String] = []
        var bullets: [AttributedString] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            blocks.append(.paragraph(inline(joined)))
            paragraph = []
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullet(bullets))
            bullets = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flushParagraph(); flushBullets(); continue }

            if line.hasPrefix("#") {
                flushParagraph(); flushBullets()
                let level = line.prefix(while: { $0 == "#" }).count
                let title = line.drop(while: { $0 == "#" || $0 == " " })
                blocks.append(.heading(String(title), level: min(level, 3)))
                continue
            }
            if line.range(of: #"^[-–—_*]{3,}$"#, options: .regularExpression) != nil {
                flushParagraph(); flushBullets()
                blocks.append(.divider)
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
                || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                flushParagraph()
                let content = line.replacingOccurrences(of: #"^([-*+]|\d+\.)\s+"#,
                                                        with: "", options: .regularExpression)
                bullets.append(inline(content))
                continue
            }
            flushBullets()
            paragraph.append(line)
        }
        flushParagraph()
        flushBullets()
        return blocks
    }

    /// Inline markdown (bold/italic/code/links) via Foundation's parser.
    nonisolated private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
    }

    nonisolated private static func prettyJSON(_ s: String) -> String? {
        guard s.hasPrefix("{") || s.hasPrefix("["),
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: out, encoding: .utf8) else { return nil }
        return str
    }
}

// MARK: - Block rendering

private struct BlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(Theme.body).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let title, let level):
            Text(title)
                .font(Theme.mono(level == 1 ? 16 : level == 2 ? 14.5 : 13.5,
                                 weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 4)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Theme.body).foregroundStyle(Theme.amber)
                        Text(item).font(Theme.body).foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .code(let code, let language):
            CodeBox(code: code, badge: language.isEmpty ? "code" : language,
                    tint: Theme.blue)

        case .json(let pretty):
            CodeBox(code: pretty, badge: "json", tint: Theme.green)

        case .html(let html):
            VStack(alignment: .leading, spacing: 6) {
                CodeBox(code: html, badge: "html", tint: Theme.amber)
                Button {
                    previewHTML(html)
                } label: {
                    Label("PREVIEW IN BROWSER", systemImage: "safari")
                        .font(Theme.label).kerning(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.panelAlt).clipShape(Capsule())
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
            }

        case .divider:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func previewHTML(_ html: String) {
        Task.detached(priority: .userInitiated) {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("athena-preview-\(UUID().uuidString.prefix(6)).html")
            try? html.write(to: file, atomically: true, encoding: .utf8)
            await MainActor.run { NSWorkspace.shared.open(file) }
        }
    }
}

private struct CodeBox: View {
    let code: String
    let badge: String
    let tint: Color
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(badge.uppercased())
                    .font(Theme.mono(8, weight: .semibold)).kerning(1)
                    .foregroundStyle(tint)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.mono(9))
                        .foregroundStyle(copied ? Theme.green : Theme.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panelAlt)

            ScrollView([.horizontal, .vertical]) {
                Text(code)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .background(Theme.bg.opacity(0.7))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}
