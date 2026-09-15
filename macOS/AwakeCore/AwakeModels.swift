import Foundation

enum TimerPreset: String, CaseIterable, Identifiable {
  case off
  case oneHour
  case twoHours
  case fourHours
  case eightHours
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: "Off"
    case .oneHour: "1 hour"
    case .twoHours: "2 hours"
    case .fourHours: "4 hours"
    case .eightHours: "8 hours"
    case .custom: "Custom"
    }
  }

  func duration(customMinutes: Int) -> TimeInterval? {
    switch self {
    case .off: nil
    case .oneHour: 60 * 60
    case .twoHours: 2 * 60 * 60
    case .fourHours: 4 * 60 * 60
    case .eightHours: 8 * 60 * 60
    case .custom: TimeInterval(max(1, customMinutes) * 60)
    }
  }
}

enum BatterySafetyThreshold: Int, CaseIterable, Identifiable {
  case off = 0
  case ten = 10
  case twenty = 20
  case thirty = 30

  var id: Int { rawValue }
  var title: String { self == .off ? "Off" : "\(rawValue)%" }
}

enum AwakeStopReason: Equatable {
  case user
  case timer
  case battery(percent: Int, threshold: Int)
  case thermal
  case quit

  var message: String {
    switch self {
    case .user: "Turned off"
    case .timer: "Timer elapsed"
    case .battery(let percent, let threshold):
      "Battery reached \(percent)% (safety threshold: \(threshold)%)"
    case .thermal: "Serious thermal pressure continued for 3 minutes"
    case .quit: "App quit"
    }
  }
}

struct PowerSnapshot: Equatable {
  let batteryPercentage: Int?
  let isOnACPower: Bool
}

extension ProcessInfo.ThermalState {
  var displayName: String {
    switch self {
    case .nominal: "Nominal"
    case .fair: "Fair"
    case .serious: "Serious"
    case .critical: "Critical"
    @unknown default: "Unknown"
    }
  }

  var isSeriousOrWorse: Bool {
    self == .serious || self == .critical
  }
}
