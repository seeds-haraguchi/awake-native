import SwiftUI

@main
struct AwakeApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate
  @StateObject private var controller = AwakeController()

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(controller: controller)
        .onAppear {
          lifecycleDelegate.controller = controller
        }
    } label: {
      Label(
        controller.isAwake ? "AwakeはONです" : "AwakeはOFFです",
        systemImage: controller.isAwake ? "sun.max.fill" : "moon.zzz"
      )
    }
    .menuBarExtraStyle(.window)
  }
}
