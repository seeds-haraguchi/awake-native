import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
  weak var controller: AwakeController?
  private var terminationInProgress = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationInProgress else { return .terminateLater }
    guard let controller, controller.isAwake else { return .terminateNow }

    terminationInProgress = true
    controller.prepareForTermination {
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
