import Foundation

@objc protocol AwakeHelperProtocol {
  func status(reply: @escaping (Bool, Bool, String?, String?) -> Void)
  func enable(sessionIdentifier: String, reply: @escaping (Bool, String?) -> Void)
  func heartbeat(sessionIdentifier: String, reply: @escaping (Bool, String?) -> Void)
  func disable(sessionIdentifier: String, reply: @escaping (Bool, String?) -> Void)
  func restoreOrphanedState(reply: @escaping (Bool, String?) -> Void)
}
