import Foundation
import IOKit.ps

enum SystemPowerMonitor {
  static func snapshot() -> PowerSnapshot {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
      return PowerSnapshot(batteryPercentage: nil, isOnACPower: true)
    }

    let providingPower = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    let isOnAC = providingPower == kIOPSACPowerValue

    guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
      return PowerSnapshot(batteryPercentage: nil, isOnACPower: isOnAC)
    }

    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? [String: Any]
      else {
        continue
      }

      guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
        continue
      }

      let current = description[kIOPSCurrentCapacityKey] as? Int
      let maximum = description[kIOPSMaxCapacityKey] as? Int
      let percentage: Int?
      if let current, let maximum, maximum > 0 {
        percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
      } else {
        percentage = current
      }

      return PowerSnapshot(batteryPercentage: percentage, isOnACPower: isOnAC)
    }

    return PowerSnapshot(batteryPercentage: nil, isOnACPower: isOnAC)
  }
}
