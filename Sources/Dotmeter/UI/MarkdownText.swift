import SwiftUI

/// Renders the small markdown subset Claude is asked to use: paragraphs, bullets, numbered items, inline bold/italic.
struct MarkdownText: View {
    var text: String
    var streaming: Bool = false

    private enum Block {
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case heading(String)
    }

    var body: some View {
        let blocks = parse(streaming ? text + " ▍" : text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    inline(s)
                case .heading(let s):
                    inline(s).fontWeight(.semibold).padding(.top, 2)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s)
                    }
                    .padding(.leading, 3)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        inline(s)
                    }
                    .padding(.leading, 1)
                }
            }
        }
        .font(.system(size: 12.5))
        .lineSpacing(2.5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(s)
    }

    private func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let marker = ["- ", "* ", "• "].first(where: { line.hasPrefix($0) }) {
                flush()
                blocks.append(.bullet(String(line.dropFirst(marker.count))))
            } else if let match = line.firstMatch(of: #/^(\d{1,2})[.)]\s+(.*)$/#) {
                flush()
                blocks.append(.numbered(String(match.1), String(match.2)))
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4, !line.dropFirst(2).dropLast(2).contains("**") {
                flush()
                blocks.append(.heading(line))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
