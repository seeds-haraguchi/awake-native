import Foundation
import Security

enum AwakeConstants {
  static let appBundleIdentifier = "jp.co.seeds-std.Awake"
  static let helperBundleIdentifier = "jp.co.seeds-std.Awake.Helper"
  static let helperMachService = "jp.co.seeds-std.Awake.Helper"
  static let helperPlistName = "jp.co.seeds-std.Awake.Helper.plist"
  static let helperExecutableName = "AwakeHelper"

  static let heartbeatInterval: TimeInterval = 10
  static let heartbeatTimeout: TimeInterval = 45

  /// Formats a build as "0.1.0 (1)"; the app and the helper share both version build settings.
  static func buildVersion(from info: [String: Any]?) -> String? {
    guard let version = info?["CFBundleShortVersionString"] as? String,
      let build = info?["CFBundleVersion"] as? String
    else { return nil }
    return "\(version) (\(build))"
  }
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

  /// Read once at launch. After Awake.app is replaced, a still-running helper can no longer resolve its own
  /// signature from disk, and a late lookup would fall back to the identifier-only requirement above.
  static let currentTeamIdentifier: String? = {
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
  }()
}
