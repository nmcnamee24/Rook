import SwiftUI
import VisionKit

struct RookMobileQRScanner: UIViewControllerRepresentable {
  let onCode: (String) -> Void
  let onError: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onCode: onCode)
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: false,
      isPinchToZoomEnabled: true,
      isGuidanceEnabled: true,
      isHighlightingEnabled: true
    )
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
    guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
      onError("QR scanning is unavailable on this iPhone.")
      return
    }
    guard !controller.isScanning else { return }
    do {
      try controller.startScanning()
    } catch {
      onError(error.localizedDescription)
    }
  }

  static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
    controller.stopScanning()
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    private let onCode: (String) -> Void
    private var didScan = false

    init(onCode: @escaping (String) -> Void) {
      self.onCode = onCode
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !didScan else { return }
      for item in addedItems {
        guard case .barcode(let barcode) = item,
          let value = barcode.payloadStringValue
        else { continue }
        didScan = true
        dataScanner.stopScanning()
        onCode(value)
        return
      }
    }
  }
}
