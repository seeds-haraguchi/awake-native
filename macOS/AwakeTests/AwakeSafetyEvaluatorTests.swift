import XCTest

@testable import Awake

final class AwakeSafetyEvaluatorTests: XCTestCase {
  private let startUptime: TimeInterval = 10_000

  func testTimerStopsAtDeadline() {
    var evaluator = AwakeSafetyEvaluator()
    let reason = evaluator.evaluate(
      nowUptime: startUptime,
      timerDeadlineUptime: startUptime,
      batteryThreshold: .off,
      power: PowerSnapshot(batteryPercentage: 100, isOnACPower: true),
      thermalSafetyEnabled: false,
      thermalState: .nominal
    )
    XCTAssertEqual(reason, .timer)
  }

  func testBatteryStopsAtThresholdOnlyOnBatteryPower() {
    var evaluator = AwakeSafetyEvaluator()
    let onBattery = evaluator.evaluate(
      nowUptime: startUptime,
      timerDeadlineUptime: nil,
      batteryThreshold: .twenty,
      power: PowerSnapshot(batteryPercentage: 20, isOnACPower: false),
      thermalSafetyEnabled: false,
      thermalState: .nominal
    )
    XCTAssertEqual(onBattery, .battery(percent: 20, threshold: 20))

    let onAC = evaluator.evaluate(
      nowUptime: startUptime,
      timerDeadlineUptime: nil,
      batteryThreshold: .twenty,
      power: PowerSnapshot(batteryPercentage: 10, isOnACPower: true),
      thermalSafetyEnabled: false,
      thermalState: .nominal
    )
    XCTAssertNil(onAC)
  }

  func testShortThermalPressureDoesNotStopAwake() {
    var evaluator = AwakeSafetyEvaluator()
    XCTAssertNil(evaluateThermal(&evaluator, state: .serious, after: 0))
    XCTAssertNil(evaluateThermal(&evaluator, state: .serious, after: 179))
  }

  func testSustainedThermalPressureStopsAfterThreeMinutes() {
    var evaluator = AwakeSafetyEvaluator()
    XCTAssertNil(evaluateThermal(&evaluator, state: .serious, after: 0))
    XCTAssertEqual(evaluateThermal(&evaluator, state: .critical, after: 180), .thermal)
  }

  func testThermalRecoveryResetsSustainWindow() {
    var evaluator = AwakeSafetyEvaluator()
    XCTAssertNil(evaluateThermal(&evaluator, state: .serious, after: 0))
    XCTAssertNil(evaluateThermal(&evaluator, state: .nominal, after: 120))
    XCTAssertNil(evaluateThermal(&evaluator, state: .serious, after: 200))
    XCTAssertNil(evaluateThermal(&evaluator, state: .serious, after: 379))
    XCTAssertEqual(evaluateThermal(&evaluator, state: .serious, after: 380), .thermal)
  }

  func testParsesPMSetSleepDisabledState() {
    XCTAssertEqual(
      PMSetStateParser.parseSleepDisabled(
        from: "System-wide power settings:\n SleepDisabled\t\t1\n"
      ),
      true
    )
    XCTAssertEqual(PMSetStateParser.parseSleepDisabled(from: " SleepDisabled 0\n"), false)
    XCTAssertNil(PMSetStateParser.parseSleepDisabled(from: " sleep 1\n"))
  }

  func testUserFacingStatusTextUsesJapanese() {
    XCTAssertEqual(TimerPreset.off.title, "オフ")
    XCTAssertEqual(TimerPreset.custom.title, "任意時間")
    XCTAssertEqual(BatterySafetyThreshold.off.title, "オフ")
    XCTAssertEqual(ProcessInfo.ThermalState.nominal.displayName, "通常")
    XCTAssertEqual(AwakeStopReason.timer.message, "タイマーが終了したため、Awakeをオフにしました")
  }

  @MainActor
  func testCustomTimerMinutesClampsWithoutRecursion() throws {
    let suiteName = "AwakeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let controller = AwakeController(defaults: defaults, startsServices: false)

    controller.customTimerMinutes = 91
    XCTAssertEqual(controller.customTimerMinutes, 91)
    XCTAssertEqual(defaults.integer(forKey: "customTimerMinutes"), 91)

    controller.customTimerMinutes = 0
    XCTAssertEqual(controller.customTimerMinutes, 1)
    XCTAssertEqual(defaults.integer(forKey: "customTimerMinutes"), 1)

    controller.customTimerMinutes = 7 * 24 * 60 + 1
    XCTAssertEqual(controller.customTimerMinutes, 7 * 24 * 60)
    XCTAssertEqual(defaults.integer(forKey: "customTimerMinutes"), 7 * 24 * 60)
  }

  private func evaluateThermal(
    _ evaluator: inout AwakeSafetyEvaluator,
    state: ProcessInfo.ThermalState,
    after seconds: TimeInterval
  ) -> AwakeStopReason? {
    evaluator.evaluate(
      nowUptime: startUptime + seconds,
      timerDeadlineUptime: nil,
      batteryThreshold: .off,
      power: PowerSnapshot(batteryPercentage: 100, isOnACPower: true),
      thermalSafetyEnabled: true,
      thermalState: state
    )
  }
}
