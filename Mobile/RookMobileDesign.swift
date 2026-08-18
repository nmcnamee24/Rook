import SwiftUI

enum RookMobilePalette {
  // Semantic system surfaces let iOS own contrast, vibrancy, and appearance changes.
  static let groupedBackground = Color(uiColor: .systemGroupedBackground)
  static let surface = Color(uiColor: .secondarySystemGroupedBackground)
  static let paper = groupedBackground
  static let paperBright = Color(uiColor: .systemBackground)
  static let ink = Color.primary
  static let muted = Color.secondary
  static let faint = Color.secondary.opacity(0.72)
  static let separator = Color(uiColor: .separator)
  static let line = separator
  static let accent = Color(red: 70 / 255, green: 130 / 255, blue: 180 / 255)
  static let green = Color(uiColor: .systemGreen)
}

struct RookMobileCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RookMobilePalette.surface,
        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
      )
  }
}

extension Text {
  static func rookMarkdown(_ value: String) -> Text {
    guard
      let attributed = try? AttributedString(
        markdown: value,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      )
    else { return Text(value) }
    return Text(attributed)
  }
}
