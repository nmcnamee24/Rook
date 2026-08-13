import SwiftUI

@main
struct RookMobileApp: App {
  @StateObject private var model: RookMobileViewModel

  init() {
    _model = StateObject(
      wrappedValue: RookMobileViewModel(
        preview: CommandLine.arguments.contains("--ui-preview")
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      RookMobileRootView(model: model)
        .preferredColorScheme(.light)
    }
  }
}
