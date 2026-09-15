import Foundation
import IOKit.pwr_mgt

enum PowerAssertionError: LocalizedError {
  case creationFailed(IOReturn)

  var errorDescription: String? {
    switch self {
    case .creationFailed(let code):
      "Unable to create the idle-sleep assertion (IOKit error \(code))."
    }
  }
}

final class PowerAssertionController {
  private var assertionID: IOPMAssertionID?

  var isActive: Bool { assertionID != nil }

  func acquire() throws {
    guard assertionID == nil else { return }

    var newID = IOPMAssertionID(0)
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "Awake: keep the Mac available for long-running work" as CFString,
      &newID
    )
    guard result == kIOReturnSuccess else {
      throw PowerAssertionError.creationFailed(result)
    }
    assertionID = newID
  }

  func release() {
    guard let assertionID else { return }
    IOPMAssertionRelease(assertionID)
    self.assertionID = nil
  }

  deinit {
    release()
  }
}
