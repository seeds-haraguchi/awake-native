import Foundation
import ServiceManagement

enum HelperClientError: LocalizedError {
  case notRegistered
  case requiresApproval
  case notFound
  case appleSignatureRequired
  case registrationFailed(Error)
  case unregistrationFailed(Error)
  case connectionFailed(String)
  case helperNotResponding
  case operationFailed(String)

  /// The request never reached a running helper, so the helper cannot have acted on it.
  var isHelperUnreachable: Bool {
    switch self {
    case .connectionFailed, .helperNotResponding: true
    default: false
    }
  }

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
    case .unregistrationFailed(let error):
      "特権ヘルパーの登録を削除できませんでした。詳細: \(error.localizedDescription)"
    case .connectionFailed(let message):
      "特権ヘルパーと通信できませんでした。詳細: \(message)"
    case .helperNotResponding:
      "特権ヘルパーが応答しません。Awakeを再起動して、もう一度お試しください。"
    case .operationFailed(let message):
      message
    }
  }
}

@MainActor
final class HelperClient {
  private nonisolated static let replyTimeout: TimeInterval = 10

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

  func unregister() async throws {
    invalidate()
    switch service.status {
    case .notRegistered, .notFound:
      return
    default:
      break
    }
    do {
      try await service.unregister()
    } catch {
      throw HelperClientError.unregistrationFailed(error)
    }
  }

  /// Submits the daemon again from this app bundle. When Awake.app is replaced while its daemon is registered,
  /// the status stays `.enabled` but launchd can no longer find the helper executable.
  func reregister() async throws {
    try await unregister()
    try registerIfNeeded()
  }

  func openApprovalSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func status() async throws -> (enabled: Bool, ownedByAwake: Bool, sessionIdentifier: String?) {
    try await call { proxy, gate in
      proxy.status(reply: Self.statusReply(gate))
    }
  }

  func enable(sessionIdentifier: String) async throws {
    try await call { proxy, gate in
      proxy.enable(sessionIdentifier: sessionIdentifier, reply: Self.operationReply(gate))
    }
  }

  func heartbeat(sessionIdentifier: String) async throws {
    try await call { proxy, gate in
      proxy.heartbeat(sessionIdentifier: sessionIdentifier, reply: Self.operationReply(gate))
    }
  }

  func disable(sessionIdentifier: String) async throws {
    try await call { proxy, gate in
      proxy.disable(sessionIdentifier: sessionIdentifier, reply: Self.operationReply(gate))
    }
  }

  func restoreOrphanedState() async throws {
    try await call { proxy, gate in
      proxy.restoreOrphanedState(reply: Self.operationReply(gate))
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

  /// Sends one XPC request and waits for its reply, an XPC error, or the timeout, whichever comes first.
  /// Without the timeout, a request to a registered daemon that launchd cannot start waits forever.
  private func call<Value: Sendable>(
    _ send: (AwakeHelperProtocol, ReplyGate<Value>) -> Void
  ) async throws -> Value {
    let connection = activeConnection()
    let connectionIdentifier = ObjectIdentifier(connection)
    var timeoutTask: Task<Void, Never>?
    defer { timeoutTask?.cancel() }

    return try await withCheckedThrowingContinuation { continuation in
      let gate = ReplyGate(continuation)
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.replyTimeout))
        guard !Task.isCancelled,
          gate.resume(with: .failure(HelperClientError.helperNotResponding))
        else { return }
        self?.dropConnection(connectionIdentifier)
      }

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler(Self.errorHandler(gate))
          as? AwakeHelperProtocol
      else {
        gate.resume(with: .failure(HelperClientError.connectionFailed("XPCインターフェースが無効です。")))
        return
      }
      send(proxy, gate)
    }
  }

  private func dropConnection(_ connectionIdentifier: ObjectIdentifier) {
    guard let connection, ObjectIdentifier(connection) == connectionIdentifier else { return }
    invalidate()
  }

  // Reply blocks run on XPC queues, so they are built outside the main actor.
  private nonisolated static func errorHandler<Value: Sendable>(_ gate: ReplyGate<Value>) -> @Sendable (Error) -> Void {
    { error in
      gate.resume(with: .failure(HelperClientError.connectionFailed(error.localizedDescription)))
    }
  }

  private nonisolated static func statusReply(
    _ gate: ReplyGate<(enabled: Bool, ownedByAwake: Bool, sessionIdentifier: String?)>
  ) -> @Sendable (Bool, Bool, String?, String?) -> Void {
    { enabled, ownedByAwake, sessionIdentifier, errorMessage in
      if let errorMessage {
        gate.resume(with: .failure(HelperClientError.operationFailed(errorMessage)))
      } else {
        gate.resume(with: .success((enabled, ownedByAwake, sessionIdentifier)))
      }
    }
  }

  private nonisolated static func operationReply(_ gate: ReplyGate<Void>) -> @Sendable (Bool, String?) -> Void {
    { success, errorMessage in
      gate.resume(
        with: success
          ? .success(())
          : .failure(HelperClientError.operationFailed(errorMessage ?? "ヘルパーの処理に失敗しました。"))
      )
    }
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
}

/// Resumes a continuation at most once; the XPC reply, the XPC error handler, and the timeout race each other.
private final class ReplyGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(_ continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  @discardableResult
  func resume(with result: Result<Value, Error>) -> Bool {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
    return pending != nil
  }
}
