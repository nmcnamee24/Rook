import AppKit
import SwiftUI

private final class RookGlassHostingController<Content: View>: NSViewController {
  private let hostingController: NSHostingController<Content>

  init(rootView: Content) {
    hostingController = NSHostingController(rootView: rootView)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let glassView = NSGlassEffectView()
    glassView.style = .regular
    glassView.tintColor = NSColor(
      calibratedRed: 70 / 255,
      green: 130 / 255,
      blue: 180 / 255,
      alpha: 0.08
    )
    glassView.cornerRadius = 18
    addChild(hostingController)
    glassView.contentView = hostingController.view
    view = glassView
  }
}

final class RookWindowController: NSWindowController, NSWindowDelegate {
  init(model: RookDashboardModel) {
    let rootView = RookDashboardView(model: model)
    let glassHostingController = RookGlassHostingController(rootView: rootView)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 840),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    window.title = "Rook"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = false
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.hasShadow = true
    window.contentMinSize = NSSize(width: 1_060, height: 720)
    window.backgroundColor = .clear
    window.contentViewController = glassHostingController
    window.collectionBehavior = [.fullScreenPrimary]

    super.init(window: window)
    window.delegate = self

    if !window.setFrameUsingName("RookCommandCenterV2") {
      window.center()
    }
    window.setFrameAutosaveName("RookCommandCenterV2")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func showRook() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
}
