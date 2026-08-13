import SwiftUI

enum RookMobilePalette {
  // Matches the desktop Steel Blue Rook palette exactly.
  static let paper = Color(red: 247 / 255, green: 246 / 255, blue: 242 / 255)
  static let paperBright = Color.white
  static let ink = Color(red: 25 / 255, green: 26 / 255, blue: 29 / 255)
  static let muted = Color(red: 111 / 255, green: 112 / 255, blue: 109 / 255)
  static let faint = muted.opacity(0.72)
  static let line = Color(red: 222 / 255, green: 220 / 255, blue: 213 / 255)
  static let accent = Color(red: 70 / 255, green: 130 / 255, blue: 180 / 255)
  static let green = Color(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
}

struct RookMobileCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RookMobilePalette.paperBright,
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(RookMobilePalette.line.opacity(0.72), lineWidth: 1)
      }
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
