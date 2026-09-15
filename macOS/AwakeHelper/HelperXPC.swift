import Foundation

final class HelperClientEndpoint: NSObject, AwakeHelperProtocol {
  private let connectionIdentifier: UUID
  private let service: HelperService

  init(connectionIdentifier: UUID, service: HelperService) {
    self.connectionIdentifier = connectionIdentifier
    self.service = service
  }

  func status(reply: @escaping (Bool, Bool, String?, String?) -> Void) {
    service.status(reply: reply)
  }

  func enable(sessionIdentifier: String, reply: @escaping (Bool, String?) -> Void) {
    service.enable(
      sessionIdentifier: sessionIdentifier,
      connectionIdentifier: connectionIdentifier,
      reply: reply
    )
  }

  func heartbeat(sessionIdentifier: String, reply: @escaping (Bool, String?) -> Void) {
    service.heartbeat(
      sessionIdentifier: sessionIdentifier,
      connectionIdentifier: connectionIdentifier,
      reply: reply
    )
  }

  func disable(sessionIdentifier: String, reply: @escaping (Bool, String?) -> Void) {
    service.disable(
      sessionIdentifier: sessionIdentifier,
      connectionIdentifier: connectionIdentifier,
      reply: reply
    )
  }

  func restoreOrphanedState(reply: @escaping (Bool, String?) -> Void) {
    service.restoreOrphanedState(reply: reply)
  }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let service: HelperService

  init(service: HelperService) {
    self.service = service
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    let connectionIdentifier = UUID()
    let endpoint = HelperClientEndpoint(
      connectionIdentifier: connectionIdentifier, service: service)
    connection.exportedInterface = NSXPCInterface(with: AwakeHelperProtocol.self)
    connection.exportedObject = endpoint
    connection.invalidationHandler = { [weak service] in
      service?.connectionInvalidated(connectionIdentifier)
    }
    connection.activate()
    return true
  }
}
