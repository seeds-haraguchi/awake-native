import Foundation
import OSLog

private final class CallbackBox<Callback>: @unchecked Sendable {
  let callback: Callback

  init(_ callback: Callback) {
    self.callback = callback
  }
}

final class HelperService: @unchecked Sendable {
  private struct ActiveLease {
    let sessionIdentifier: String
    let connectionIdentifier: UUID
    var expiresAt: DispatchTime
  }

  private let queue = DispatchQueue(label: "jp.co.seeds-std.Awake.Helper.state")
  private let store = LeaseStore()
  private let pmset = PMSetController()
  private let logger = Logger(subsystem: AwakeConstants.helperBundleIdentifier, category: "helper")
  private var activeLease: ActiveLease?
  private var watchdog: DispatchSourceTimer?

  init() {
    queue.sync {
      recoverMarkedState(reason: "helper startup")
      startWatchdog()
    }
  }

  func status(reply: @escaping (Bool, Bool, String?, String?) -> Void) {
    let reply = CallbackBox(reply)
    queue.async {
      let owned = self.activeLease != nil || self.store.markerExists
      do {
        let sleepDisabled = try self.pmset.readSleepDisabled()
        reply.callback(sleepDisabled, owned, self.activeLease?.sessionIdentifier, nil)
      } catch {
        reply.callback(
          owned, owned, self.activeLease?.sessionIdentifier, error.localizedDescription)
      }
    }
  }

  func enable(
    sessionIdentifier: String,
    connectionIdentifier: UUID,
    reply: @escaping (Bool, String?) -> Void
  ) {
    let reply = CallbackBox(reply)
    queue.async {
      guard UUID(uuidString: sessionIdentifier) != nil else {
        reply.callback(false, "セッション識別子が無効です。")
        return
      }

      if let lease = self.activeLease {
        guard lease.sessionIdentifier == sessionIdentifier,
          lease.connectionIdentifier == connectionIdentifier
        else {
          reply.callback(false, "別のAwakeセッションがすでに有効です。")
          return
        }
        self.activeLease?.expiresAt = self.nextHeartbeatDeadline()
        reply.callback(true, nil)
        return
      }

      if self.store.markerExists {
        self.recoverMarkedState(reason: "enable preflight")
        guard !self.store.markerExists else {
          reply.callback(false, "以前のスリープ設定の復旧がまだ完了していません。")
          return
        }
      }

      do {
        guard try !self.pmset.readSleepDisabled() else {
          reply.callback(
            false,
            "Awake以外でSleepDisabledがすでに有効です。設定したツールで無効にしてからAwakeを開始してください。"
          )
          return
        }

        // The durable marker is intentionally committed before changing global power state.
        try self.store.save(LeaseMarker(sessionIdentifier: sessionIdentifier, createdAt: Date()))
        do {
          try self.pmset.setSleepDisabled(true)
        } catch {
          // The command may have changed the setting even when verification failed.
          // Keep the marker unless an explicit rollback is itself verified.
          do {
            try self.pmset.setSleepDisabled(false)
            try self.store.clear()
          } catch let rollbackError {
            self.logger.fault(
              "Enable rollback failed: \(rollbackError.localizedDescription, privacy: .public)"
            )
          }
          throw error
        }
        self.activeLease = ActiveLease(
          sessionIdentifier: sessionIdentifier,
          connectionIdentifier: connectionIdentifier,
          expiresAt: self.nextHeartbeatDeadline()
        )
        self.logger.notice("Awake lease enabled")
        reply.callback(true, nil)
      } catch {
        self.logger.error("Enable failed: \(error.localizedDescription, privacy: .public)")
        reply.callback(false, error.localizedDescription)
      }
    }
  }

  func heartbeat(
    sessionIdentifier: String,
    connectionIdentifier: UUID,
    reply: @escaping (Bool, String?) -> Void
  ) {
    let reply = CallbackBox(reply)
    queue.async {
      guard let lease = self.activeLease,
        lease.sessionIdentifier == sessionIdentifier,
        lease.connectionIdentifier == connectionIdentifier
      else {
        reply.callback(false, "Awakeの制御セッションが有効ではありません。")
        return
      }
      self.activeLease?.expiresAt = self.nextHeartbeatDeadline()
      reply.callback(true, nil)
    }
  }

  func disable(
    sessionIdentifier: String,
    connectionIdentifier: UUID,
    reply: @escaping (Bool, String?) -> Void
  ) {
    let reply = CallbackBox(reply)
    queue.async {
      if let lease = self.activeLease,
        lease.sessionIdentifier != sessionIdentifier
          || lease.connectionIdentifier != connectionIdentifier
      {
        reply.callback(false, "有効な制御セッションは別のAwakeセッションに属しています。")
        return
      }
      self.restore(reason: "explicit disable", reply: reply.callback)
    }
  }

  func restoreOrphanedState(reply: @escaping (Bool, String?) -> Void) {
    let reply = CallbackBox(reply)
    queue.async {
      // Only restore state for which Awake has an in-memory or durable ownership record.
      // This prevents an authenticated replacement client from changing an unrelated
      // SleepDisabled setting owned by another tool.
      self.restore(reason: "client-requested safety recovery", reply: reply.callback)
    }
  }

  func connectionInvalidated(_ connectionIdentifier: UUID) {
    queue.async {
      guard self.activeLease?.connectionIdentifier == connectionIdentifier else { return }
      self.restore(reason: "XPC connection invalidated") { _, _ in }
    }
  }

  private func startWatchdog() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
    timer.setEventHandler { [weak self] in
      guard let self else { return }

      if let lease = activeLease, DispatchTime.now() >= lease.expiresAt {
        restore(reason: "heartbeat timeout") { _, _ in }
      } else if activeLease == nil, store.markerExists {
        recoverMarkedState(reason: "pending recovery retry")
      }
    }
    watchdog = timer
    timer.activate()
  }

  private func nextHeartbeatDeadline() -> DispatchTime {
    .now() + .milliseconds(Int(AwakeConstants.heartbeatTimeout * 1_000))
  }

  private func recoverMarkedState(reason: String) {
    guard store.markerExists else { return }
    logger.warning("Recovery marker found during \(reason, privacy: .public)")
    do {
      try pmset.setSleepDisabled(false)
      try store.clear()
      activeLease = nil
      logger.notice("Recovered the global sleep setting")
    } catch {
      // Keep the marker. The watchdog retries until restoration succeeds.
      logger.fault("Recovery failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func restore(reason: String, reply: @escaping (Bool, String?) -> Void) {
    guard activeLease != nil || store.markerExists else {
      reply(true, nil)
      return
    }

    do {
      try pmset.setSleepDisabled(false)
      try store.clear()
      activeLease = nil
      logger.notice("Awake lease restored: \(reason, privacy: .public)")
      reply(true, nil)
    } catch {
      // Retain both the lease and marker so the watchdog keeps retrying.
      logger.fault("Restore failed: \(error.localizedDescription, privacy: .public)")
      reply(false, error.localizedDescription)
    }
  }
}
