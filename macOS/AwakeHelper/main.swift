import Darwin
import Foundation
import OSLog

let logger = Logger(subsystem: AwakeConstants.helperBundleIdentifier, category: "lifecycle")
guard getuid() == 0 else {
  logger.fault("Refusing to run without root privileges")
  exit(EXIT_FAILURE)
}

// Resolve the signing identity before Awake.app can be replaced on disk.
_ = CodeSigningRequirement.currentTeamIdentifier
let service = HelperService()
let delegate = HelperListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: AwakeConstants.helperMachService)
listener.setConnectionCodeSigningRequirement(
  CodeSigningRequirement.forPeer(bundleIdentifier: AwakeConstants.appBundleIdentifier)
)
listener.delegate = delegate
logger.notice("Awake privileged helper \(HelperBuild.version, privacy: .public) started")
listener.activate()
dispatchMain()
