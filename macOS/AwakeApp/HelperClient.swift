import Foundation
import ServiceManagement

enum HelperClientError: LocalizedError {
  case notRegistered
  case requiresApproval
  case notFound
  case registrationFailed(Error)
  case connectionFailed(String)
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .notRegistered:
      "The privileged helper is not installed. Turn Awake on to request approval."
    case .requiresApproval:
      "Allow Awake in System Settings > General > Login Items, then try again."
    case .notFound:
      "The privileged helper is missing from Awake.app. Reinstall the app in /Applications."
    case .registrationFailed(let error):
      "Unable to register the privileged helper: \(error.localizedDescription)"
    case .connectionFailed(let message):
      "Unable to communicate with the privileged helper: \(message)"
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
    switch service.status {
    case .enabled:
      return
    case .requiresApproval:
      throw HelperClientError.requiresApproval
    case .notFound:
      throw HelperClientError.notFound
    case .notRegistered:
      do {
        try service.register()
      } catch {
        if service.status == .requiresApproval {
          throw HelperClientError.requiresApproval
        }
        throw HelperClientError.registrationFailed(error)
      }
      guard service.status == .enabled else {
        throw HelperClientError.requiresApproval
      }
    @unknown default:
      throw HelperClientError.notFound
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
        continuation.resume(throwing: HelperClientError.connectionFailed("Invalid XPC interface."))
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
      continuation.resume(throwing: HelperClientError.connectionFailed("Invalid XPC interface."))
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
        throwing: HelperClientError.operationFailed(errorMessage ?? "The helper operation failed.")
      )
    }
  }
}
