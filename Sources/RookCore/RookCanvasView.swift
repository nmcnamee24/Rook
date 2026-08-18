import AppKit
import Foundation
import RookKit
import SwiftUI

struct RookCanvasView: View {
  let blocks: [RookCanvasBlock]
  let mediaRootURL: URL

  init(blocks: [RookCanvasBlock], mediaRootURL: URL = RookConfig.recommended.mediaURL) {
    self.blocks = blocks
    self.mediaRootURL = mediaRootURL
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(blocks) { block in
        RookCanvasBlockView(block: block, mediaRootURL: mediaRootURL)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(.easeOut(duration: 0.24), value: blocks.map(\.id))
  }
}

private struct RookCanvasBlockView: View {
  let block: RookCanvasBlock
  let mediaRootURL: URL
  @State private var showsProposedCode = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      canvasHeader
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 15)

      Rectangle()
        .fill(RookPalette.line.opacity(0.82))
        .frame(height: 1)

      canvasBody
        .padding(20)

      if !block.asOf.isEmpty || !block.sourceLabel.isEmpty {
        Rectangle()
          .fill(RookPalette.line.opacity(0.72))
          .frame(height: 1)
        canvasFooter
          .padding(.horizontal, 20)
          .frame(height: 38)
      }
    }
    .rookGlassCard(cornerRadius: 12, tintOpacity: 0.045, castsShadow: false)
  }

  private var canvasHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: headerIcon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(RookPalette.accent)
        .frame(width: 34, height: 34)
        .background(RookPalette.accent.opacity(0.08), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text(block.title)
          .font(.system(size: 21, design: .serif))
          .foregroundStyle(RookPalette.ink)
        if !block.subtitle.isEmpty {
          Text(block.subtitle)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(RookPalette.muted)
        }
      }
      Spacer(minLength: 10)
      Text(block.kind.rawValue.uppercased())
        .font(.system(size: 9, weight: .bold))
        .tracking(0.8)
        .foregroundStyle(RookPalette.faint)
    }
  }

  @ViewBuilder
  private var canvasBody: some View {
    switch block.kind {
    case .weather:
      weatherBody
    case .calendar:
      calendarBody
    case .spotify:
      spotifyBody
    case .image:
      imageBody
    case .code:
      codeBody
    case .diagram:
      diagramBody
    case .list, .computer:
      listBody
    }
  }

  private var weatherBody: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
        VStack(spacing: 8) {
          Text(item.label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(RookPalette.muted)
            .lineLimit(1)
          Image(systemName: symbolName(item.symbol))
            .font(.system(size: 26, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(RookPalette.accent)
            .frame(height: 31)
          Text(item.value)
            .font(.system(size: 20, design: .serif))
            .foregroundStyle(RookPalette.ink)
            .lineLimit(1)
          Text(item.detail)
            .font(.system(size: 11.5))
            .foregroundStyle(RookPalette.muted)
            .lineLimit(2)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .overlay(alignment: .trailing) {
          if index < block.items.count - 1 {
            Rectangle()
              .fill(RookPalette.line.opacity(0.72))
              .frame(width: 1, height: 90)
          }
        }
      }
    }
  }

  private var calendarBody: some View {
    VStack(spacing: 0) {
      if block.items.isEmpty {
        Text("No events in this window.")
          .font(.system(size: 14))
          .foregroundStyle(RookPalette.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
          HStack(alignment: .top, spacing: 15) {
            VStack(alignment: .trailing, spacing: 2) {
              Text(displayTime(item.start))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(RookPalette.accent)
              if !item.end.isEmpty {
                Text(displayTime(item.end))
                  .font(.system(size: 10.5, weight: .medium))
                  .foregroundStyle(RookPalette.faint)
              }
            }
            .frame(width: 72, alignment: .trailing)

            ZStack(alignment: .top) {
              if index < block.items.count - 1 {
                Rectangle()
                  .fill(RookPalette.accent.opacity(0.35))
                  .frame(width: 1, height: 52)
                  .offset(y: 14)
              }
              Circle()
                .fill(RookPalette.paperBright)
                .frame(width: 11, height: 11)
                .overlay { Circle().stroke(RookPalette.accent, lineWidth: 2) }
                .padding(.top, 3)
            }
            .frame(width: 13)

            VStack(alignment: .leading, spacing: 4) {
              Text(item.label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RookPalette.ink)
              if !item.detail.isEmpty {
                Text(item.detail)
                  .font(.system(size: 11.5))
                  .foregroundStyle(RookPalette.muted)
                  .lineLimit(2)
              }
            }
            Spacer(minLength: 0)
          }
          .padding(.vertical, 8)
        }
      }
    }
  }

  private var spotifyBody: some View {
    VStack(alignment: .leading, spacing: 16) {
      if !block.body.isEmpty || !block.imageURL.isEmpty {
        HStack(alignment: .center, spacing: 16) {
          if let url = safeURL(block.imageURL) {
            AsyncImage(url: url) { phase in
              switch phase {
              case .empty:
                ProgressView().controlSize(.small)
              case .success(let image):
                image.resizable().scaledToFit()
              case .failure:
                Image(systemName: "music.note")
                  .font(.system(size: 25, weight: .semibold))
                  .foregroundStyle(RookPalette.accent)
              @unknown default:
                EmptyView()
              }
            }
            .frame(width: 82, height: 82)
            .background(RookPalette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          } else {
            Image(systemName: "music.note")
              .font(.system(size: 27, weight: .semibold))
              .foregroundStyle(RookPalette.accent)
              .frame(width: 82, height: 82)
              .background(RookPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
          }

          VStack(alignment: .leading, spacing: 5) {
            if !block.body.isEmpty {
              Text(block.body)
                .font(.system(size: 20, design: .serif))
                .foregroundStyle(RookPalette.ink)
                .lineLimit(2)
            }
            if !block.caption.isEmpty {
              Text(block.caption)
                .font(.system(size: 12.5))
                .foregroundStyle(RookPalette.muted)
                .lineLimit(2)
            }
          }
          Spacer(minLength: 0)
        }
      }

      if !block.items.isEmpty {
        if !block.body.isEmpty || !block.imageURL.isEmpty {
          Rectangle().fill(RookPalette.line.opacity(0.65)).frame(height: 1)
        }
        listBody
      }
    }
  }

  private var imageBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let assetURL = privateImageURL, let image = NSImage(contentsOf: assetURL) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity)
          .frame(minHeight: 180, maxHeight: 420)
          .background(RookPalette.paper)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .contextMenu {
            Button("Open full image") { NSWorkspace.shared.open(assetURL) }
          }
      } else if let url = safeURL(block.imageURL) {
        AsyncImage(url: url) { phase in
          switch phase {
          case .empty:
            ZStack {
              RookPalette.paper
              ProgressView()
                .controlSize(.small)
            }
          case .success(let image):
            image
              .resizable()
              .scaledToFit()
          case .failure:
            ZStack {
              RookPalette.paper
              Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(RookPalette.faint)
            }
          @unknown default:
            EmptyView()
          }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180, maxHeight: 420)
        .background(RookPalette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        if !block.caption.isEmpty {
          Text(block.caption)
            .font(.system(size: 12.5))
            .foregroundStyle(RookPalette.muted)
            .lineSpacing(3)
        }
        Spacer(minLength: 0)
        if let assetURL = privateImageURL {
          Button("Open full image") { NSWorkspace.shared.open(assetURL) }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(RookPalette.accent)
        }
      }
    }
  }

  private var codeBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !block.body.isEmpty, !block.secondaryBody.isEmpty {
        HStack(spacing: 4) {
          codeToggle("Original", proposed: false)
          codeToggle("Proposed fix", proposed: true)
          Spacer()
          if !block.language.isEmpty {
            Text(block.language.uppercased())
              .font(.system(size: 9, weight: .bold, design: .monospaced))
              .tracking(0.7)
              .foregroundStyle(RookPalette.faint)
          }
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(activeCode)
          .font(.system(size: 12.5, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.92))
          .lineSpacing(3)
          .textSelection(.enabled)
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(RookPalette.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .animation(.easeOut(duration: 0.16), value: showsProposedCode)
    }
  }

  private func codeToggle(_ label: String, proposed: Bool) -> some View {
    Button(label) {
      withAnimation(.easeOut(duration: 0.16)) { showsProposedCode = proposed }
    }
    .buttonStyle(.plain)
    .font(.system(size: 11.5, weight: .semibold))
    .foregroundStyle(showsProposedCode == proposed ? RookPalette.paperBright : RookPalette.muted)
    .padding(.horizontal, 11)
    .padding(.vertical, 6)
    .background(showsProposedCode == proposed ? RookPalette.ink : Color.clear, in: Capsule())
  }

  private var activeCode: String {
    if block.body.isEmpty { return block.secondaryBody }
    if block.secondaryBody.isEmpty { return block.body }
    return showsProposedCode ? block.secondaryBody : block.body
  }

  private var diagramBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
        HStack(alignment: .top, spacing: 14) {
          ZStack(alignment: .top) {
            if index < block.items.count - 1 {
              Rectangle()
                .fill(RookPalette.line)
                .frame(width: 1, height: 58)
                .offset(y: 31)
            }
            Image(systemName: symbolName(item.symbol))
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(RookPalette.accent)
              .frame(width: 30, height: 30)
              .background(RookPalette.accent.opacity(0.08), in: Circle())
          }
          .frame(width: 32)

          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Text(item.label)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(RookPalette.ink)
              Spacer()
              if !item.value.isEmpty {
                Text(item.value.uppercased())
                  .font(.system(size: 9, weight: .bold))
                  .tracking(0.6)
                  .foregroundStyle(RookPalette.accent)
              }
            }
            if !item.detail.isEmpty {
              Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(RookPalette.muted)
                .lineSpacing(2)
            }
          }
          .padding(.top, 4)
        }
        .padding(.bottom, index < block.items.count - 1 ? 18 : 0)
      }
    }
  }

  private var listBody: some View {
    VStack(spacing: 0) {
      if block.items.isEmpty {
        Text(block.body)
          .font(.system(size: 13.5))
          .foregroundStyle(RookPalette.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName(item.symbol))
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(RookPalette.accent)
              .frame(width: 28, height: 28)
              .background(RookPalette.accent.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
              Text(item.label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RookPalette.ink)
              if !item.detail.isEmpty {
                Text(item.detail)
                  .font(.system(size: 11.5))
                  .foregroundStyle(RookPalette.muted)
                  .lineLimit(3)
              }
            }
            Spacer(minLength: 12)
            if !item.value.isEmpty {
              Text(item.value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RookPalette.ink)
                .multilineTextAlignment(.trailing)
            }
          }
          .padding(.vertical, 10)
          if index < block.items.count - 1 {
            Rectangle()
              .fill(RookPalette.line.opacity(0.65))
              .frame(height: 1)
              .padding(.leading, 40)
          }
        }
      }
    }
  }

  private var canvasFooter: some View {
    HStack(spacing: 8) {
      if !block.asOf.isEmpty {
        Text("AS OF \(displayAsOf(block.asOf).uppercased())")
      }
      if !block.asOf.isEmpty, !block.sourceLabel.isEmpty { Text("·") }
      if let url = safeURL(block.sourceURL), !block.sourceLabel.isEmpty {
        Link(block.sourceLabel, destination: url)
          .foregroundStyle(RookPalette.accent)
      } else if !block.sourceLabel.isEmpty {
        Text(block.sourceLabel)
      }
      Spacer()
    }
    .font(.system(size: 9.5, weight: .bold))
    .tracking(0.55)
    .foregroundStyle(RookPalette.faint)
  }

  private var headerIcon: String {
    switch block.kind {
    case .weather: return "sun.max.fill"
    case .calendar: return "calendar"
    case .spotify: return "music.note"
    case .image: return "photo"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .diagram: return "point.3.connected.trianglepath.dotted"
    case .list: return "list.bullet"
    case .computer: return "macbook.and.iphone"
    }
  }

  private func symbolName(_ symbol: RookCanvasSymbol) -> String {
    switch symbol {
    case .sun: return "sun.max.fill"
    case .partlyCloudy: return "cloud.sun.fill"
    case .cloudy: return "cloud.fill"
    case .rain: return "cloud.rain.fill"
    case .storm: return "cloud.bolt.rain.fill"
    case .snow: return "cloud.snow.fill"
    case .wind: return "wind"
    case .fog: return "cloud.fog.fill"
    case .calendar: return "calendar"
    case .clock: return "clock.fill"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .image: return "photo"
    case .diagram: return "point.3.connected.trianglepath.dotted"
    case .computer: return "macbook.and.iphone"
    case .music: return "music.note"
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    }
  }

  private func safeURL(_ value: String) -> URL? {
    RookImageSourceValidator.publicHTTPSURL(value)
  }

  private var privateImageURL: URL? {
    RookMediaStore(rootURL: mediaRootURL).imageURL(for: block.imageAssetID)
  }

  private func displayTime(_ value: String) -> String {
    guard let date = parseDate(value) else { return value }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "America/New_York")
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
  }

  private func displayAsOf(_ value: String) -> String {
    guard let date = parseDate(value) else { return value }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "America/New_York")
    formatter.dateFormat = "MMM d · h:mm a"
    return formatter.string(from: date)
  }

  private func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
}
