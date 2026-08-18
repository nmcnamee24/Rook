import SwiftUI

enum RookGlassStyle {
  static let windowTint = Color(red: 70 / 255, green: 130 / 255, blue: 180 / 255)
  static let highlight = Color.white.opacity(0.30)
  static let shadow = Color.black.opacity(0.13)
}

extension View {
  func rookGlassPlane(tintOpacity: Double = 0.04) -> some View {
    background(Color.clear)
      .glassEffect(
        .clear.tint(RookGlassStyle.windowTint.opacity(tintOpacity)),
        in: Rectangle()
      )
      .overlay(alignment: .top) {
        Rectangle()
          .fill(RookGlassStyle.highlight.opacity(0.52))
          .frame(height: 0.5)
          .allowsHitTesting(false)
      }
  }

  func rookGlassCard(
    cornerRadius: CGFloat = 14,
    tint: Color = RookGlassStyle.windowTint,
    tintOpacity: Double = 0.06,
    interactive: Bool = false,
    castsShadow: Bool = true
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return background(RookPalette.ink.opacity(0.018), in: shape)
      .glassEffect(
        Glass.regular.tint(tint.opacity(tintOpacity)).interactive(interactive),
        in: shape
      )
      .overlay {
        shape
          .strokeBorder(
            LinearGradient(
              colors: [RookGlassStyle.highlight, RookPalette.line.opacity(0.82)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
          .allowsHitTesting(false)
      }
      .shadow(
        color: castsShadow ? RookGlassStyle.shadow : .clear,
        radius: castsShadow ? 18 : 0,
        x: 0,
        y: castsShadow ? 8 : 0
      )
  }

  func rookGlassInset(
    cornerRadius: CGFloat = 9,
    tint: Color = RookGlassStyle.windowTint,
    tintOpacity: Double = 0.035
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return background(RookPalette.ink.opacity(0.025), in: shape)
      .glassEffect(.clear.tint(tint.opacity(tintOpacity)), in: shape)
      .overlay {
        shape
          .strokeBorder(RookPalette.line.opacity(0.86), lineWidth: 1)
          .allowsHitTesting(false)
      }
  }

  func rookGlassSheet(cornerRadius: CGFloat = 22) -> some View {
    rookGlassCard(
      cornerRadius: cornerRadius,
      tintOpacity: 0.075,
      castsShadow: true
    )
  }
}
