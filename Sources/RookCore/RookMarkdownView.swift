import SwiftUI

struct RookMarkdownView: View {
    enum Density {
        case primary
        case history

        var bodySize: CGFloat { self == .primary ? 16.5 : 15.5 }
        var blockSpacing: CGFloat { self == .primary ? 16 : 13 }
    }

    let markdown: String
    var density: Density = .primary

    private var blocks: [RookMarkdownBlock] {
        RookMarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.blockSpacing) {
            ForEach(blocks) { block in
                blockView(block, isLead: block.id == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: RookMarkdownBlock, isLead: Bool) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .foregroundStyle(RookPalette.ink)
                .padding(.top, isLead ? 0 : 4)

        case .paragraph(let text):
            inlineText(text)
                .font(isLead ? .system(size: 23, weight: .regular, design: .serif) : .system(size: density.bodySize))
                .foregroundStyle(RookPalette.ink)
                .lineSpacing(isLead ? 5 : 4)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Circle()
                    .fill(RookPalette.accent)
                    .frame(width: 5, height: 5)
                    .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] }
                inlineText(text)
                    .font(.system(size: density.bodySize))
                    .foregroundStyle(RookPalette.ink)
                    .lineSpacing(3)
            }

        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RookPalette.paperBright)
                    .frame(width: 22, height: 22)
                    .background(RookPalette.accent, in: Circle())
                inlineText(text)
                    .font(.system(size: density.bodySize))
                    .foregroundStyle(RookPalette.ink)
                    .lineSpacing(3)
            }

        case .quote(let text):
            inlineText(text)
                .font(.system(size: density.bodySize, design: .serif).italic())
                .foregroundStyle(RookPalette.muted)
                .lineSpacing(4)
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(RookPalette.accent.opacity(0.7))
                        .frame(width: 2)
                }

        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(RookPalette.ink)
                    .padding(14)
            }
            .background(RookPalette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .table(let headers, let rows):
            markdownTable(headers: headers, rows: rows)

        case .rule:
            Rectangle()
                .fill(RookPalette.line.opacity(0.9))
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 30, weight: .regular, design: .serif)
        case 2: return .system(size: 23, weight: .regular, design: .serif)
        default: return .system(size: 14, weight: .bold)
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        return Text(attributed)
    }

    private func markdownTable(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true)
                Rectangle()
                    .fill(RookPalette.accent.opacity(0.55))
                    .frame(height: 1)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, isHeader: false)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(RookPalette.line.opacity(0.7))
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(RookPalette.paperBright.opacity(0.62))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(RookPalette.line.opacity(0.82), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inlineText(cell)
                    .font(.system(size: isHeader ? 11.5 : 13.5, weight: isHeader ? .bold : .regular))
                    .foregroundStyle(isHeader ? RookPalette.muted : RookPalette.ink)
                    .frame(width: 145, alignment: .leading)
            }
        }
        .padding(.vertical, isHeader ? 10 : 12)
    }
}

private struct RookMarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case quote(String)
        case code(String)
        case table([String], [[String]])
        case rule
    }

    let id: Int
    let kind: Kind
}

private enum RookMarkdownParser {
    static func parse(_ markdown: String) -> [RookMarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var kinds: [RookMarkdownBlock.Kind] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            kinds.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCode {
                    kinds.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                }
                inCode.toggle()
                index += 1
                continue
            }

            if inCode {
                code.append(raw)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if index + 1 < lines.count,
               trimmed.contains("|"),
               isTableDivider(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    rows.append(tableCells(candidate))
                    index += 1
                }
                kinds.append(.table(headers, rows))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                kinds.append(.heading(heading.level, heading.text))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                kinds.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                kinds.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let bullet = bullet(from: trimmed) {
                flushParagraph()
                kinds.append(.bullet(bullet))
            } else if let numbered = numbered(from: trimmed) {
                flushParagraph()
                kinds.append(.numbered(numbered.number, numbered.text))
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }

        flushParagraph()
        if !code.isEmpty { kinds.append(.code(code.joined(separator: "\n"))) }
        if kinds.isEmpty { kinds.append(.paragraph(markdown)) }
        return kinds.enumerated().map { RookMarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func bullet(from line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numbered(from line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: "."),
              let number = Int(line[..<dot]) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after].isWhitespace else { return nil }
        return (number, String(line[line.index(after: after)...]))
    }

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.filter { $0 == "-" }.count >= 3 &&
                cell.trimmingCharacters(in: CharacterSet(charactersIn: "-: ")).isEmpty
        }
    }
}
