import Foundation

enum PMSetStateParser {
  static func parseSleepDisabled(from output: String) -> Bool? {
    var recognizedOutput = false
    for line in output.split(whereSeparator: \Character.isNewline) {
      if line.trimmingCharacters(in: .whitespaces) == "Currently in use:" {
        recognizedOutput = true
      }
      let fields = line.split(whereSeparator: \Character.isWhitespace)
      guard fields.count >= 2,
        String(fields[0]).caseInsensitiveCompare("SleepDisabled") == .orderedSame
      else {
        continue
      }
      if fields[1] == "1" { return true }
      if fields[1] == "0" { return false }
    }
    // pmset omits the SleepDisabled line until `disablesleep` has been set on this Mac,
    // so a well-formed report without it means the default: sleep is not disabled.
    return recognizedOutput ? false : nil
  }
}
