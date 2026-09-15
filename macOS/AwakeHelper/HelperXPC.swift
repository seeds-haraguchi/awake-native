import Foundation
import MachO

enum HelperBuild {
  /// Read from the Info.plist linked into this executable. Reading Awake.app/Contents/Info.plist instead would
  /// report the replacement app's build after an update, while this process still runs the old code.
  static let version: String = {
    var size: UInt = 0
    let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
    guard let bytes = getsectiondata(header, "__TEXT", "__info_plist", &size),
      let info = try? PropertyListSerialization.propertyList(
        from: Data(bytes: bytes, count: Int(size)), format: nil) as? [String: Any],
      let version = AwakeConstants.buildVersion(from: info)
    else { return "unknown" }
    return version
  }()
}

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

  func version(reply: @escaping (String) -> Void) {
    reply(HelperBuild.version)
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
    connection.setCodeSigningRequirement(
      CodeSigningRequirement.forPeer(bundleIdentifier: AwakeConstants.appBundleIdentifier)
    )
    connection.exportedInterface = NSXPCInterface(with: AwakeHelperProtocol.self)
    connection.exportedObject = endpoint
    connection.invalidationHandler = { [weak service] in
      service?.connectionInvalidated(connectionIdentifier)
    }
    connection.activate()
    return true
  }
}
