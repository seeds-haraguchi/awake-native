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
    case .off: "オフ"
    case .oneHour: "1時間"
    case .twoHours: "2時間"
    case .fourHours: "4時間"
    case .eightHours: "8時間"
    case .custom: "任意時間"
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
  var title: String { self == .off ? "オフ" : "\(rawValue)%" }
}

enum AwakeStopReason: Equatable {
  case user
  case timer
  case battery(percent: Int, threshold: Int)
  case thermal
  case quit

  var message: String {
    switch self {
    case .user: "Awakeをオフにしました"
    case .timer: "タイマーが終了したため、Awakeをオフにしました"
    case .battery(let percent, let threshold):
      "バッテリー残量が\(percent)%になったため、Awakeをオフにしました（設定値: \(threshold)%）"
    case .thermal: "高い温度状態が3分間継続したため、Awakeをオフにしました"
    case .quit: "アプリの終了時にAwakeをオフにしました"
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
    case .nominal: "通常"
    case .fair: "やや高い"
    case .serious: "高い"
    case .critical: "危険"
    @unknown default: "不明"
    }
  }

  var isSeriousOrWorse: Bool {
    self == .serious || self == .critical
  }
}
