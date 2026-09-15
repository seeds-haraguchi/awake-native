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
      "Awakeのヘルパーはroot権限で実行する必要があります。"
    case .launchFailed(let error):
      "pmsetを起動できませんでした。詳細: \(error.localizedDescription)"
    case .commandFailed(let status, let message):
      "pmsetが終了ステータス\(status)で失敗しました。\(message)"
    case .unableToReadState:
      "pmsetからシステムのSleepDisabled状態を取得できませんでした。"
    case .stateMismatch(let expectedDisabled):
      "pmsetは完了しましたが、SleepDisabledが\(expectedDisabled ? 1 : 0)になっていません。"
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
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "エラー出力なし"
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
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "エラー出力なし"
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
