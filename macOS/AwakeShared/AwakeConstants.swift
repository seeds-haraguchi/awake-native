import Foundation
import Security

enum AwakeConstants {
  static let appBundleIdentifier = "com.example.Awake"
  static let helperBundleIdentifier = "com.example.Awake.Helper"
  static let helperMachService = "com.example.Awake.Helper"
  static let helperPlistName = "com.example.Awake.Helper.plist"
  static let helperExecutableName = "AwakeHelper"

  static let heartbeatInterval: TimeInterval = 10
  static let heartbeatTimeout: TimeInterval = 45
}

enum CodeSigningRequirement {
  static func forPeer(bundleIdentifier: String) -> String {
    guard let teamIdentifier = currentTeamIdentifier else {
      // Ad-hoc signatures have no team identifier. This fallback is only useful for
      // local development; release builds are checked separately before packaging.
      return "identifier \"\(bundleIdentifier)\""
    }

    return "anchor apple generic and identifier \"\(bundleIdentifier)\" "
      + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
  }

  static var currentTeamIdentifier: String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
      return nil
    }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }

    // kSecCodeInfoTeamIdentifier is only populated when kSecCSSigningInformation is requested.
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
      let dictionary = information as? [CFString: Any]
    else {
      return nil
    }

    return dictionary[kSecCodeInfoTeamIdentifier] as? String
  }
}
