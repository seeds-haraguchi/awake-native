import Foundation

struct AwakeSafetyEvaluator {
  static let thermalSustainDuration: TimeInterval = 3 * 60

  private(set) var thermalPressureBeganAtUptime: TimeInterval?

  mutating func reset() {
    thermalPressureBeganAtUptime = nil
  }

  mutating func evaluate(
    nowUptime: TimeInterval,
    timerDeadlineUptime: TimeInterval?,
    batteryThreshold: BatterySafetyThreshold,
    power: PowerSnapshot,
    thermalSafetyEnabled: Bool,
    thermalState: ProcessInfo.ThermalState
  ) -> AwakeStopReason? {
    if let timerDeadlineUptime, nowUptime >= timerDeadlineUptime {
      return .timer
    }

    if batteryThreshold != .off,
      !power.isOnACPower,
      let percentage = power.batteryPercentage,
      percentage <= batteryThreshold.rawValue
    {
      return .battery(percent: percentage, threshold: batteryThreshold.rawValue)
    }

    guard thermalSafetyEnabled else {
      thermalPressureBeganAtUptime = nil
      return nil
    }

    guard thermalState.isSeriousOrWorse else {
      thermalPressureBeganAtUptime = nil
      return nil
    }

    if let thermalPressureBeganAtUptime {
      if nowUptime - thermalPressureBeganAtUptime >= Self.thermalSustainDuration {
        return .thermal
      }
    } else {
      thermalPressureBeganAtUptime = nowUptime
    }

    return nil
  }
}
