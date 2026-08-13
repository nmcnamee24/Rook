import SwiftUI

struct RookMobileCanvasView: View {
  let block: RookCanvasBlock
  @State private var showsProposedCode = true

  var body: some View {
    RookMobileCard {
      VStack(alignment: .leading, spacing: 15) {
        header
        bodyContent
        if !block.asOf.isEmpty || !block.sourceLabel.isEmpty {
          HStack(spacing: 6) {
            if !block.asOf.isEmpty { Text("As of \(block.asOf)") }
            if !block.asOf.isEmpty, !block.sourceLabel.isEmpty { Text("·") }
            if !block.sourceLabel.isEmpty { Text(block.sourceLabel) }
          }
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(RookMobilePalette.faint)
        }
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: symbolName(block.items.first?.symbol ?? fallbackSymbol))
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(RookMobilePalette.accent)
        .frame(width: 32, height: 32)
        .background(RookMobilePalette.accent.opacity(0.08), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(block.title)
          .font(.system(size: 20, weight: .medium, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
        if !block.subtitle.isEmpty {
          Text(block.subtitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(RookMobilePalette.muted)
        }
      }
      Spacer()
      Text(block.kind.rawValue.uppercased())
        .font(.system(size: 8, weight: .black))
        .tracking(0.8)
        .foregroundStyle(RookMobilePalette.faint)
    }
  }

  @ViewBuilder
  private var bodyContent: some View {
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
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(block.items) { item in
          VStack(spacing: 7) {
            Text(item.label.uppercased())
              .font(.system(size: 9, weight: .black))
              .tracking(0.6)
              .foregroundStyle(RookMobilePalette.muted)
            Image(systemName: symbolName(item.symbol))
              .font(.system(size: 23, weight: .medium))
              .foregroundStyle(RookMobilePalette.accent)
            Text(item.value)
              .font(.system(size: 18, design: .serif))
              .foregroundStyle(RookMobilePalette.ink)
            Text(item.detail)
              .font(.system(size: 10))
              .foregroundStyle(RookMobilePalette.faint)
              .lineLimit(2)
          }
          .frame(width: 92)
          .padding(.vertical, 10)
          .background(RookMobilePalette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
      }
    }
  }

  private var calendarBody: some View {
    VStack(spacing: 0) {
      ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
        HStack(alignment: .top, spacing: 12) {
          Text(displayTime(item.start))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(RookMobilePalette.accent)
            .frame(width: 58, alignment: .trailing)
          VStack(spacing: 0) {
            Circle()
              .fill(RookMobilePalette.paperBright)
              .frame(width: 10, height: 10)
              .overlay { Circle().stroke(RookMobilePalette.accent, lineWidth: 2) }
            if index < block.items.count - 1 {
              Rectangle()
                .fill(RookMobilePalette.accent.opacity(0.3))
                .frame(width: 1, height: 42)
            }
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(item.label)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(RookMobilePalette.ink)
            if !item.detail.isEmpty {
              Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(RookMobilePalette.muted)
                .lineLimit(2)
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var spotifyBody: some View {
    VStack(alignment: .leading, spacing: 13) {
      if !block.body.isEmpty || !block.imageURL.isEmpty {
        HStack(alignment: .center, spacing: 13) {
          if let url = safeImageURL(block.imageURL) {
            AsyncImage(url: url) { phase in
              switch phase {
              case .empty:
                ProgressView().controlSize(.small)
              case .success(let image):
                image.resizable().scaledToFit()
              case .failure:
                Image(systemName: "music.note")
                  .foregroundStyle(RookMobilePalette.accent)
              @unknown default:
                EmptyView()
              }
            }
            .frame(width: 64, height: 64)
            .background(RookMobilePalette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 9))
          } else {
            Image(systemName: "music.note")
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(RookMobilePalette.accent)
              .frame(width: 64, height: 64)
              .background(RookMobilePalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
          }

          VStack(alignment: .leading, spacing: 4) {
            if !block.body.isEmpty {
              Text(block.body)
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(RookMobilePalette.ink)
                .lineLimit(2)
            }
            if !block.caption.isEmpty {
              Text(block.caption)
                .font(.system(size: 11))
                .foregroundStyle(RookMobilePalette.muted)
                .lineLimit(2)
            }
          }
          Spacer(minLength: 0)
        }
      }

      if !block.items.isEmpty {
        if !block.body.isEmpty || !block.imageURL.isEmpty {
          Rectangle().fill(RookMobilePalette.line.opacity(0.65)).frame(height: 1)
        }
        listBody
      }
    }
  }

  private var imageBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let url = safeImageURL(block.imageURL) {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          ProgressView().frame(maxWidth: .infinity, minHeight: 180)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
      } else if block.imageAssetID != nil {
        VStack(spacing: 8) {
          Image(systemName: "photo")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(RookMobilePalette.accent)
          Text("Generated image available on your Mac")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(RookMobilePalette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RookMobilePalette.paper, in: RoundedRectangle(cornerRadius: 12))
      }
      if !block.caption.isEmpty {
        Text(block.caption)
          .font(.system(size: 12))
          .foregroundStyle(RookMobilePalette.muted)
      }
    }
  }

  private var codeBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !block.body.isEmpty, !block.secondaryBody.isEmpty {
        Picker("Code version", selection: $showsProposedCode) {
          Text("Original").tag(false)
          Text("Proposed").tag(true)
        }
        .pickerStyle(.segmented)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        Text(showsProposedCode && !block.secondaryBody.isEmpty ? block.secondaryBody : block.body)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.white.opacity(0.92))
          .padding(14)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RookMobilePalette.ink, in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private var diagramBody: some View {
    VStack(spacing: 0) {
      ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
        HStack(alignment: .top, spacing: 12) {
          Text("\(index + 1)")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RookMobilePalette.accent, in: Circle())
          VStack(alignment: .leading, spacing: 3) {
            Text(item.label)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(RookMobilePalette.ink)
            if !item.detail.isEmpty {
              Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(RookMobilePalette.muted)
            }
          }
          Spacer()
        }
        .padding(.vertical, 7)
      }
    }
  }

  private var listBody: some View {
    VStack(spacing: 10) {
      ForEach(block.items) { item in
        HStack(alignment: .top, spacing: 11) {
          Image(systemName: symbolName(item.symbol))
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(RookMobilePalette.accent)
            .frame(width: 22)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.label)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(RookMobilePalette.ink)
            if !item.detail.isEmpty {
              Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(RookMobilePalette.muted)
            }
          }
          Spacer()
          if !item.value.isEmpty {
            Text(item.value)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(RookMobilePalette.faint)
          }
        }
      }
    }
  }

  private var fallbackSymbol: RookCanvasSymbol {
    switch block.kind {
    case .weather: return .sun
    case .calendar: return .calendar
    case .spotify: return .music
    case .image: return .image
    case .code: return .code
    case .diagram: return .diagram
    case .computer: return .computer
    case .list: return .info
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
    case .clock: return "clock"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .image: return "photo"
    case .diagram: return "point.3.connected.trianglepath.dotted"
    case .computer: return "macbook.and.iphone"
    case .music: return "music.note"
    case .info: return "info.circle"
    case .warning: return "exclamationmark.triangle"
    }
  }

  private func displayTime(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else { return value }
    return date.formatted(date: .omitted, time: .shortened)
  }

  private func safeImageURL(_ value: String) -> URL? {
    RookImageSourceValidator.publicHTTPSURL(value)
  }
}
