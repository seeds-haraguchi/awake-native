import Foundation
import ServiceManagement

enum HelperClientError: LocalizedError {
  case notRegistered
  case requiresApproval
  case notFound
  case appleSignatureRequired
  case registrationFailed(Error)
  case connectionFailed(String)
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .notRegistered:
      "特権ヘルパーの登録状態を確認できませんでした。Awakeを再起動して、もう一度お試しください。"
    case .requiresApproval:
      "「システム設定」>「一般」>「ログイン項目」でAwakeを許可してから、もう一度お試しください。"
    case .notFound:
      "Awake.app内に特権ヘルパーまたはLaunchDaemon設定がありません。アプリを再インストールしてください。"
    case .appleSignatureRequired:
      "このAwake.appはApple発行の証明書で署名されていないため、特権ヘルパーを登録できません。署名済みのアプリを「アプリケーション」フォルダに配置してください。"
    case .registrationFailed(let error):
      "特権ヘルパーを登録できませんでした。詳細: \(error.localizedDescription)"
    case .connectionFailed(let message):
      "特権ヘルパーと通信できませんでした。詳細: \(message)"
    case .operationFailed(let message):
      message
    }
  }
}

@MainActor
final class HelperClient {
  private let service = SMAppService.daemon(plistName: AwakeConstants.helperPlistName)
  private var connection: NSXPCConnection?
  var onConnectionLost: (() -> Void)?

  var serviceStatus: SMAppService.Status { service.status }

  func registerIfNeeded() throws {
    try validateEmbeddedHelper()
    guard CodeSigningRequirement.currentTeamIdentifier != nil else {
      throw HelperClientError.appleSignatureRequired
    }

    switch service.status {
    case .enabled:
      return
    case .requiresApproval:
      throw HelperClientError.requiresApproval
    case .notRegistered, .notFound:
      do {
        try service.register()
      } catch {
        if service.status == .requiresApproval {
          throw HelperClientError.requiresApproval
        }
        throw HelperClientError.registrationFailed(error)
      }
      guard service.status == .enabled else {
        if service.status == .requiresApproval {
          throw HelperClientError.requiresApproval
        }
        throw HelperClientError.notRegistered
      }
    @unknown default:
      throw HelperClientError.notRegistered
    }
  }

  func openApprovalSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func status() async throws -> (enabled: Bool, ownedByAwake: Bool, sessionIdentifier: String?) {
    let connection = activeConnection()
    return try await withCheckedThrowingContinuation { continuation in
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          continuation.resume(
            throwing: HelperClientError.connectionFailed(error.localizedDescription))
        }) as? AwakeHelperProtocol
      else {
        continuation.resume(throwing: HelperClientError.connectionFailed("XPCインターフェースが無効です。"))
        return
      }
      proxy.status { enabled, ownedByAwake, sessionIdentifier, errorMessage in
        if let errorMessage {
          continuation.resume(throwing: HelperClientError.operationFailed(errorMessage))
        } else {
          continuation.resume(returning: (enabled, ownedByAwake, sessionIdentifier))
        }
      }
    }
  }

  func enable(sessionIdentifier: String) async throws {
    let connection = activeConnection()
    try await withCheckedThrowingContinuation { continuation in
      guard let proxy = operationProxy(connection: connection, continuation: continuation) else {
        return
      }
      proxy.enable(sessionIdentifier: sessionIdentifier) { success, errorMessage in
        Self.resume(continuation, success: success, errorMessage: errorMessage)
      }
    }
  }

  func heartbeat(sessionIdentifier: String) async throws {
    let connection = activeConnection()
    try await withCheckedThrowingContinuation { continuation in
      guard let proxy = operationProxy(connection: connection, continuation: continuation) else {
        return
      }
      proxy.heartbeat(sessionIdentifier: sessionIdentifier) { success, errorMessage in
        Self.resume(continuation, success: success, errorMessage: errorMessage)
      }
    }
  }

  func disable(sessionIdentifier: String) async throws {
    let connection = activeConnection()
    try await withCheckedThrowingContinuation { continuation in
      guard let proxy = operationProxy(connection: connection, continuation: continuation) else {
        return
      }
      proxy.disable(sessionIdentifier: sessionIdentifier) { success, errorMessage in
        Self.resume(continuation, success: success, errorMessage: errorMessage)
      }
    }
  }

  func restoreOrphanedState() async throws {
    let connection = activeConnection()
    try await withCheckedThrowingContinuation { continuation in
      guard let proxy = operationProxy(connection: connection, continuation: continuation) else {
        return
      }
      proxy.restoreOrphanedState { success, errorMessage in
        Self.resume(continuation, success: success, errorMessage: errorMessage)
      }
    }
  }

  func invalidate() {
    connection?.invalidationHandler = nil
    connection?.invalidate()
    connection = nil
  }

  private func activeConnection() -> NSXPCConnection {
    if let connection { return connection }
    let newConnection = makeConnection()
    connection = newConnection
    return newConnection
  }

  private func validateEmbeddedHelper() throws {
    let bundleURL = Bundle.main.bundleURL
    let helperURL = bundleURL.appendingPathComponent(
      "Contents/MacOS/\(AwakeConstants.helperExecutableName)"
    )
    let daemonPlistURL = bundleURL.appendingPathComponent(
      "Contents/Library/LaunchDaemons/\(AwakeConstants.helperPlistName)"
    )

    guard FileManager.default.isExecutableFile(atPath: helperURL.path),
      FileManager.default.fileExists(atPath: daemonPlistURL.path)
    else {
      throw HelperClientError.notFound
    }
  }

  private func operationProxy(
    connection: NSXPCConnection,
    continuation: CheckedContinuation<Void, Error>
  ) -> AwakeHelperProtocol? {
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        continuation.resume(
          throwing: HelperClientError.connectionFailed(error.localizedDescription))
      }) as? AwakeHelperProtocol
    else {
      continuation.resume(throwing: HelperClientError.connectionFailed("XPCインターフェースが無効です。"))
      return nil
    }
    return proxy
  }

  private func makeConnection() -> NSXPCConnection {
    let connection = NSXPCConnection(
      machServiceName: AwakeConstants.helperMachService,
      options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(with: AwakeHelperProtocol.self)
    connection.setCodeSigningRequirement(
      CodeSigningRequirement.forPeer(bundleIdentifier: AwakeConstants.helperBundleIdentifier)
    )
    connection.interruptionHandler = { [weak self, weak connection] in
      Task { @MainActor in
        guard let self, self.connection === connection else { return }
        self.connection = nil
        self.onConnectionLost?()
      }
    }
    connection.invalidationHandler = { [weak self, weak connection] in
      Task { @MainActor in
        guard let self, self.connection === connection else { return }
        self.connection = nil
        self.onConnectionLost?()
      }
    }
    connection.activate()
    return connection
  }

  private static func resume(
    _ continuation: CheckedContinuation<Void, Error>,
    success: Bool,
    errorMessage: String?
  ) {
    if success {
      continuation.resume()
    } else {
      continuation.resume(
        throwing: HelperClientError.operationFailed(errorMessage ?? "ヘルパーの処理に失敗しました。")
      )
    }
  }
}
