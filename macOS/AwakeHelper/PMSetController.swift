import Foundation

enum PMSetError: LocalizedError {
  case notRunningAsRoot
  case launchFailed(Error)
  case commandFailed(status: Int32, message: String)
  case unableToReadState
  case stateMismatch(expectedDisabled: Bool)

  var errorDescription: String? {
    switch self {
    case .notRunningAsRoot:
      "The Awake helper must run as root."
    case .launchFailed(let error):
      "Unable to launch pmset: \(error.localizedDescription)"
    case .commandFailed(let status, let message):
      "pmset failed with status \(status): \(message)"
    case .unableToReadState:
      "pmset did not report the system SleepDisabled state."
    case .stateMismatch(let expectedDisabled):
      "pmset completed, but SleepDisabled was not \(expectedDisabled ? 1 : 0)."
    }
  }
}

struct PMSetController {
  func setSleepDisabled(_ disabled: Bool) throws {
    guard getuid() == 0 else { throw PMSetError.notRunningAsRoot }

    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe

    do {
      try process.run()
    } catch {
      throw PMSetError.launchFailed(error)
    }
    process.waitUntilExit()

    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let message =
        String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "No error output"
      throw PMSetError.commandFailed(status: process.terminationStatus, message: message)
    }

    guard try readSleepDisabled() == disabled else {
      throw PMSetError.stateMismatch(expectedDisabled: disabled)
    }
  }

  func readSleepDisabled() throws -> Bool {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
    } catch {
      throw PMSetError.launchFailed(error)
    }
    process.waitUntilExit()

    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let message =
        String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "No error output"
      throw PMSetError.commandFailed(status: process.terminationStatus, message: message)
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else {
      throw PMSetError.unableToReadState
    }

    guard let state = PMSetStateParser.parseSleepDisabled(from: output) else {
      throw PMSetError.unableToReadState
    }
    return state
  }
}
