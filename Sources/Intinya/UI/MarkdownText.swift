import SwiftUI

/// A small block-level markdown renderer.
///
/// `AttributedString(markdown:)` handles inline formatting but collapses block
/// structure — headings come out the same size as body text, and lists lose
/// their bullets. Since notes are mostly headings and bullets, blocks are parsed
/// here and inline formatting is delegated to AttributedString.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Block.parse(markdown).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: [22.0, 18.0, 15.0][min(level - 1, 2)], weight: .semibold))
                .padding(.top, level == 1 ? 4 : 2)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(item)).font(Theme.Font.body)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(inline(item)).font(Theme.Font.body)
                    }
                }
            }

        case .code(let text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }

        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Theme.system.opacity(0.5))
                    .frame(width: 3)
                Text(inline(text))
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }

        case .rule:
            Divider()

        case .paragraph(let text):
            Text(inline(text)).font(Theme.Font.body)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Blocks

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case numbered([String])
        case code(String)
        case quote(String)
        case rule

        static func parse(_ source: String) -> [Block] {
            var blocks: [Block] = []
            var lines = source.components(separatedBy: .newlines)[...]

            func flush(_ buffer: inout [String]) {
                guard !buffer.isEmpty else { return }
                blocks.append(.paragraph(buffer.joined(separator: " ")))
                buffer.removeAll()
            }

            var paragraph: [String] = []

            while let raw = lines.first {
                lines = lines.dropFirst()
                let line = raw.trimmingCharacters(in: .whitespaces)

                if line.isEmpty { flush(&paragraph); continue }

                if line.hasPrefix("```") {
                    flush(&paragraph)
                    var code: [String] = []
                    while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        code.append(next)
                        lines = lines.dropFirst()
                    }
                    if !lines.isEmpty { lines = lines.dropFirst() }   // closing fence
                    blocks.append(.code(code.joined(separator: "\n")))
                    continue
                }

                if line == "---" || line == "***" {
                    flush(&paragraph)
                    blocks.append(.rule)
                    continue
                }

                if line.hasPrefix("#") {
                    flush(&paragraph)
                    let level = line.prefix(while: { $0 == "#" }).count
                    let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: max(1, level), text: text))
                    continue
                }

                if line.hasPrefix("> ") {
                    flush(&paragraph)
                    blocks.append(.quote(String(line.dropFirst(2))))
                    continue
                }

                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    flush(&paragraph)
                    var items = [String(line.dropFirst(2))]
                    while let next = lines.first?.trimmingCharacters(in: .whitespaces),
                          next.hasPrefix("- ") || next.hasPrefix("* ") {
                        items.append(String(next.dropFirst(2)))
                        lines = lines.dropFirst()
                    }
                    blocks.append(.bullet(items))
                    continue
                }

                if let match = numberedItem(line) {
                    flush(&paragraph)
                    var items = [match]
                    while let next = lines.first?.trimmingCharacters(in: .whitespaces),
                          let item = numberedItem(next) {
                        items.append(item)
                        lines = lines.dropFirst()
                    }
                    blocks.append(.numbered(items))
                    continue
                }

                paragraph.append(line)
            }

            flush(&paragraph)
            return blocks
        }

        /// Returns the text of a `1. item` line, or nil.
        private static func numberedItem(_ line: String) -> String? {
            let digits = line.prefix(while: \.isNumber)
            guard !digits.isEmpty else { return nil }
            let rest = line.dropFirst(digits.count)
            guard rest.hasPrefix(". ") else { return nil }
            return String(rest.dropFirst(2))
        }
    }
}
