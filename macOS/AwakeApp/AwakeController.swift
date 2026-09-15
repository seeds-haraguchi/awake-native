import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AwakeController: ObservableObject {
  @Published private(set) var isAwake = false
  @Published private(set) var isTransitioning = false
  @Published private(set) var power = SystemPowerMonitor.snapshot()
  @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
  @Published private(set) var timerDeadline: Date?
  @Published private(set) var lastStopReason: String?
  @Published var errorMessage: String?
  /// Mirrors `SMAppService.mainApp`; the user can also change it in System Settings.
  @Published private(set) var launchAtLoginStatus = SMAppService.mainApp.status

  @Published var timerPreset: TimerPreset {
    didSet {
      defaults.set(timerPreset.rawValue, forKey: Keys.timerPreset)
      if isAwake { resetTimerDeadline() }
    }
  }
  @Published var customTimerMinutes: Int {
    didSet {
      // Assigning a @Published property inside its own didSet re-enters didSet,
      // so only reassign when clamping actually changes the value.
      let clamped = min(7 * 24 * 60, max(1, customTimerMinutes))
      guard clamped == customTimerMinutes else {
        customTimerMinutes = clamped
        return
      }
      defaults.set(customTimerMinutes, forKey: Keys.customTimerMinutes)
      if isAwake, timerPreset == .custom { resetTimerDeadline() }
    }
  }
  @Published var batteryThreshold: BatterySafetyThreshold {
    didSet { defaults.set(batteryThreshold.rawValue, forKey: Keys.batteryThreshold) }
  }
  @Published var thermalSafetyEnabled: Bool {
    didSet {
      defaults.set(thermalSafetyEnabled, forKey: Keys.thermalSafety)
      if !thermalSafetyEnabled { safetyEvaluator.reset() }
    }
  }

  var timerRemaining: String {
    guard isAwake, let timerDeadlineUptime else { return "オフ" }
    let seconds = max(
      0,
      Int((timerDeadlineUptime - ProcessInfo.processInfo.systemUptime).rounded(.up))
    )
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }

  var helperRequiresApproval: Bool {
    helperClient.serviceStatus == .requiresApproval
  }

  var launchAtLogin: Bool {
    launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
  }

  var launchAtLoginRequiresApproval: Bool {
    launchAtLoginStatus == .requiresApproval
  }

  private enum Keys {
    static let timerPreset = "timerPreset"
    static let customTimerMinutes = "customTimerMinutes"
    static let batteryThreshold = "batteryThreshold"
    static let thermalSafety = "thermalSafety"
  }

  private let defaults: UserDefaults
  private let helperClient: HelperClient
  private let assertionController = PowerAssertionController()
  private var safetyEvaluator = AwakeSafetyEvaluator()
  private var sessionIdentifier: String?
  private var timerDeadlineUptime: TimeInterval?
  private var tickTimer: Timer?
  private var connectionRecoveryTask: Task<Void, Never>?
  private var lastPowerRefreshUptime: TimeInterval = 0
  private var lastHeartbeatUptime: TimeInterval = 0

  init(
    defaults: UserDefaults = .standard,
    helperClient: HelperClient = HelperClient(),
    startsServices: Bool = true
  ) {
    self.defaults = defaults
    self.helperClient = helperClient

    let presetValue = defaults.string(forKey: Keys.timerPreset) ?? TimerPreset.off.rawValue
    timerPreset = TimerPreset(rawValue: presetValue) ?? .off

    let savedMinutes = defaults.integer(forKey: Keys.customTimerMinutes)
    customTimerMinutes = savedMinutes > 0 ? savedMinutes : 90

    if defaults.object(forKey: Keys.batteryThreshold) == nil {
      batteryThreshold = .twenty
    } else {
      batteryThreshold =
        BatterySafetyThreshold(
          rawValue: defaults.integer(forKey: Keys.batteryThreshold)
        ) ?? .twenty
    }

    if defaults.object(forKey: Keys.thermalSafety) == nil {
      thermalSafetyEnabled = true
    } else {
      thermalSafetyEnabled = defaults.bool(forKey: Keys.thermalSafety)
    }

    helperClient.onConnectionLost = { [weak self] in
      self?.handleConnectionLoss()
    }
    // Tests disable this so they never touch the privileged helper installed on the host.
    guard startsServices else { return }
    startMonitoring()
    Task { await recoverAtLaunch() }
  }

  func setAwake(_ enabled: Bool) {
    guard enabled != isAwake, !isTransitioning else { return }
    Task {
      if enabled {
        await startAwake()
      } else {
        await stopAwake(reason: .user)
      }
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    errorMessage = nil
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      errorMessage =
        enabled
        ? "ログイン時に起動する設定にできませんでした。詳細: \(error.localizedDescription)"
        : "ログイン時に起動しない設定にできませんでした。詳細: \(error.localizedDescription)"
    }
    refreshLaunchAtLoginStatus()
    if launchAtLoginRequiresApproval {
      errorMessage = "「システム設定」>「一般」>「ログイン項目」でAwakeを許可してください。"
    }
  }

  func refreshLaunchAtLoginStatus() {
    launchAtLoginStatus = SMAppService.mainApp.status
  }

  func openHelperApprovalSettings() {
    helperClient.openApprovalSettings()
  }

  func prepareForTermination(completion: @escaping () -> Void) {
    guard isAwake || assertionController.isActive else {
      helperClient.invalidate()
      completion()
      return
    }

    Task {
      await stopAwake(reason: .quit)
      helperClient.invalidate()
      completion()
    }
  }

  /// Restores the sleep setting, removes the helper registration, and clears saved settings.
  /// Returns `true` when `SleepDisabled` still reads 1 afterwards.
  func uninstall() async throws -> Bool {
    guard !isTransitioning else {
      throw HelperClientError.operationFailed("処理中です。完了してからもう一度お試しください。")
    }

    isTransitioning = true
    errorMessage = nil
    defer { isTransitioning = false }

    if helperClient.serviceStatus == .enabled {
      do {
        // Restores the active session, if any, and clears the durable recovery marker.
        try await helperClient.restoreOrphanedState()
      } catch let error as HelperClientError where error.isHelperUnreachable {
        // A helper that launchd cannot start can neither restore nor hold SleepDisabled, so removing
        // its registration loses nothing. The caller reports a SleepDisabled value left behind.
      } catch {
        throw HelperClientError.operationFailed(
          "スリープ設定を復旧できなかったため、アンインストールを中止しました。詳細: \(error.localizedDescription)")
      }
    }
    try await helperClient.unregister()
    // Leaving the login item registered would point it at the app in the Trash.
    if launchAtLogin {
      try? await SMAppService.mainApp.unregister()
    }

    assertionController.release()
    sessionIdentifier = nil
    isAwake = false
    timerDeadline = nil
    timerDeadlineUptime = nil

    for key in [
      Keys.timerPreset, Keys.customTimerMinutes, Keys.batteryThreshold, Keys.thermalSafety,
    ] {
      defaults.removeObject(forKey: key)
    }
    return Self.readSleepDisabled() == true
  }

  private static func readSleepDisabled() -> Bool? {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return PMSetStateParser.parseSleepDisabled(from: String(decoding: data, as: UTF8.self))
  }

  private func startAwake() async {
    isTransitioning = true
    errorMessage = nil
    defer { isTransitioning = false }

    do {
      try helperClient.registerIfNeeded()
      let sessionIdentifier = UUID().uuidString
      try await retryingAfterReregistration {
        try await helperClient.enable(sessionIdentifier: sessionIdentifier)
      }
      do {
        try assertionController.acquire()
      } catch {
        try? await helperClient.disable(sessionIdentifier: sessionIdentifier)
        throw error
      }

      self.sessionIdentifier = sessionIdentifier
      isAwake = true
      lastStopReason = nil
      safetyEvaluator.reset()
      resetTimerDeadline()
      lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
      refreshSystemStatus()
    } catch {
      assertionController.release()
      sessionIdentifier = nil
      timerDeadline = nil
      timerDeadlineUptime = nil
      isAwake = false
      errorMessage = error.localizedDescription
    }
  }

  private func stopAwake(reason: AwakeStopReason) async {
    guard !isTransitioning else { return }
    isTransitioning = true
    errorMessage = nil
    defer { isTransitioning = false }

    guard let sessionIdentifier else {
      do {
        if isAwake {
          // A failed re-registration at launch leaves no helper to restore with, so register it again first.
          try helperClient.registerIfNeeded()
          try await retryingAfterReregistration {
            try await helperClient.restoreOrphanedState()
          }
        }
        assertionController.release()
        isAwake = false
        timerDeadline = nil
        timerDeadlineUptime = nil
        lastStopReason = reason.message
      } catch {
        assertionController.release()
        isAwake = true
        errorMessage =
          "スリープ設定の復旧をまだ確認できません。安全のためAwakeはONと表示しています。詳細: \(error.localizedDescription)"
      }
      return
    }

    do {
      try await helperClient.disable(sessionIdentifier: sessionIdentifier)
      assertionController.release()
      self.sessionIdentifier = nil
      isAwake = false
      timerDeadline = nil
      timerDeadlineUptime = nil
      safetyEvaluator.reset()
      lastStopReason = reason.message
    } catch {
      // The UI must not claim OFF while global restoration is unconfirmed.
      assertionController.release()
      isAwake = true
      errorMessage =
        "スリープ設定の復旧をまだ確認できません。ヘルパーが復旧を再試行します。詳細: \(error.localizedDescription)"
    }
  }

  private func recoverAtLaunch() async {
    guard helperClient.serviceStatus == .enabled else { return }
    do {
      // Starting the daemon also executes its marker-based startup recovery.
      let status = try await retryingAfterReregistration { try await helperClient.status() }
      if status.enabled {
        isAwake = true
        if status.ownedByAwake {
          isTransitioning = true
          try await helperClient.restoreOrphanedState()
          isAwake = false
          isTransitioning = false
          lastStopReason = "前回のセッションで残ったスリープ設定を復旧しました"
        } else {
          errorMessage =
            "Awake以外でSleepDisabledが有効になっています。他のツールが設定した状態は変更しません。"
        }
      }
    } catch {
      isAwake = true
      isTransitioning = false
      errorMessage = "起動時のスリープ設定復旧を確認できませんでした。詳細: \(error.localizedDescription)"
      return
    }
    await replaceOutdatedHelper()
  }

  /// launchd keeps the helper from the previous Awake.app running after the app is replaced, so an update
  /// only reaches the helper once it is registered again. Runs after launch recovery, when no Awake session
  /// holds SleepDisabled; a marker left by an interrupted session is still recovered by the new helper.
  private func replaceOutdatedHelper() async {
    guard !isAwake, let appVersion = AwakeConstants.buildVersion(from: Bundle.main.infoDictionary)
    else { return }

    // Blocks the switch so that no session starts on the helper that is about to be stopped.
    isTransitioning = true
    defer { isTransitioning = false }

    // A helper older than the version request never replies, so any failure means it must be replaced.
    if let helperVersion = try? await helperClient.version(), helperVersion == appVersion {
      return
    }
    do {
      try await helperClient.reregister()
      let helperVersion = try await helperClient.version()
      guard helperVersion == appVersion else {
        errorMessage =
          "補助プログラム（\(helperVersion)）をAwake \(appVersion)に更新できませんでした。Macを再起動してください。"
        return
      }
    } catch let error as HelperClientError {
      if case .requiresApproval = error {
        errorMessage = error.localizedDescription
      } else {
        errorMessage = "補助プログラムを更新できませんでした。Macを再起動してください。詳細: \(error.localizedDescription)"
      }
    } catch {
      errorMessage = "補助プログラムを更新できませんでした。Macを再起動してください。詳細: \(error.localizedDescription)"
    }
  }

  /// Runs `operation` again after re-registering the helper when the registered helper cannot be reached.
  private func retryingAfterReregistration<Value>(
    _ operation: () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operation()
    } catch let error as HelperClientError where error.isHelperUnreachable {
      try await helperClient.reregister()
      return try await operation()
    }
  }

  private func startMonitoring() {
    tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.thermalState = ProcessInfo.processInfo.thermalState
        self?.evaluateSafety()
      }
    }
  }

  private func tick() {
    let nowUptime = ProcessInfo.processInfo.systemUptime
    thermalState = ProcessInfo.processInfo.thermalState

    if nowUptime - lastPowerRefreshUptime >= 10 {
      refreshSystemStatus()
      lastPowerRefreshUptime = nowUptime
    }

    guard isAwake, !isTransitioning else { return }
    evaluateSafety(nowUptime: nowUptime)

    if nowUptime - lastHeartbeatUptime >= AwakeConstants.heartbeatInterval,
      let sessionIdentifier
    {
      lastHeartbeatUptime = nowUptime
      Task {
        do {
          try await helperClient.heartbeat(sessionIdentifier: sessionIdentifier)
        } catch {
          handleConnectionLoss()
        }
      }
    }
  }

  private func refreshSystemStatus() {
    power = SystemPowerMonitor.snapshot()
  }

  private func evaluateSafety(nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard isAwake, !isTransitioning else { return }
    if let reason = safetyEvaluator.evaluate(
      nowUptime: nowUptime,
      timerDeadlineUptime: timerDeadlineUptime,
      batteryThreshold: batteryThreshold,
      power: power,
      thermalSafetyEnabled: thermalSafetyEnabled,
      thermalState: thermalState
    ) {
      Task { await stopAwake(reason: reason) }
    }
  }

  private func resetTimerDeadline() {
    guard isAwake,
      let duration = timerPreset.duration(customMinutes: customTimerMinutes)
    else {
      timerDeadline = nil
      timerDeadlineUptime = nil
      return
    }
    timerDeadline = Date().addingTimeInterval(duration)
    timerDeadlineUptime = ProcessInfo.processInfo.systemUptime + duration
  }

  private func handleConnectionLoss() {
    guard isAwake, connectionRecoveryTask == nil else { return }
    assertionController.release()
    sessionIdentifier = nil
    timerDeadline = nil
    timerDeadlineUptime = nil
    isTransitioning = true
    errorMessage = "ヘルパーとの接続が失われました。システムのスリープ設定を復旧しています…"

    connectionRecoveryTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.connectionRecoveryTask = nil
        self.isTransitioning = false
      }

      for attempt in 0..<12 {
        do {
          try await self.helperClient.restoreOrphanedState()
          self.isAwake = false
          self.lastStopReason = "ヘルパーとの接続切断後、スリープ設定を復旧しました"
          self.errorMessage = nil
          return
        } catch {
          if attempt < 11 {
            try? await Task.sleep(for: .seconds(5))
          } else {
            self.errorMessage =
              "スリープ設定の復旧をまだ確認できません。安全のためAwakeはONと表示し、ヘルパーが復旧を再試行しています。詳細: \(error.localizedDescription)"
          }
        }
      }
    }
  }
}
