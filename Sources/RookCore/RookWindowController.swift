import AppKit
import SwiftUI

final class RookWindowController: NSWindowController, NSWindowDelegate {
    init(model: RookDashboardModel) {
        let rootView = RookDashboardView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Rook"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1_060, height: 720)
        window.backgroundColor = NSColor(calibratedRed: 0.984, green: 0.971, blue: 0.949, alpha: 1)
        window.contentViewController = hostingController
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
