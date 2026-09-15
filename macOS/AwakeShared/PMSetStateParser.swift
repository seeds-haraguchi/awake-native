import Foundation

enum PMSetStateParser {
  static func parseSleepDisabled(from output: String) -> Bool? {
    for line in output.split(whereSeparator: \Character.isNewline) {
      let fields = line.split(whereSeparator: \Character.isWhitespace)
      guard fields.count >= 2,
        String(fields[0]).caseInsensitiveCompare("SleepDisabled") == .orderedSame
      else {
        continue
      }
      if fields[1] == "1" { return true }
      if fields[1] == "0" { return false }
    }
    return nil
  }
}
