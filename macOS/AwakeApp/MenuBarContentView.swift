import AppKit
import SwiftUI

struct MenuBarContentView: View {
  @ObservedObject var controller: AwakeController

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Awake")
            .font(.title2.weight(.semibold))
          Text("MacBookの蓋を閉じても、処理を継続します。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("Awakeを有効にする", isOn: awakeBinding)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(controller.isTransitioning)
      }

      statusCard

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("タイマー")
          Picker("タイマー", selection: $controller.timerPreset) {
            ForEach(TimerPreset.allCases) { preset in
              Text(preset.title).tag(preset)
            }
          }
          .labelsHidden()
        }

        if controller.timerPreset == .custom {
          GridRow {
            Text("時間")
            Stepper(
              "\(controller.customTimerMinutes)分",
              value: $controller.customTimerMinutes,
              in: 1...(7 * 24 * 60)
            )
          }
        }

        GridRow {
          Text("バッテリー保護")
          Picker("バッテリー保護", selection: $controller.batteryThreshold) {
            ForEach(BatterySafetyThreshold.allCases) { threshold in
              Text(threshold.title).tag(threshold)
            }
          }
          .labelsHidden()
        }

        GridRow {
          Text("温度保護")
          Toggle("温度保護", isOn: $controller.thermalSafetyEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }
      }

      if let errorMessage = controller.errorMessage {
        VStack(alignment: .leading, spacing: 8) {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          if controller.helperRequiresApproval {
            Button("ログイン項目設定を開く") {
              controller.openHelperApprovalSettings()
            }
          }
        }
      } else if let reason = controller.lastStopReason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("AC電源接続中はバッテリー保護を適用しません。")
          HStack(spacing: 8) {
            Text(appVersion)
              .textSelection(.enabled)
            Button("アンインストール…") {
              confirmAndUninstall()
            }
            .buttonStyle(.link)
            .disabled(controller.isTransitioning)
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Awakeを終了") {
          NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
      }
    }
    .padding(16)
    .frame(width: 380)
  }

  private var awakeBinding: Binding<Bool> {
    Binding(
      get: { controller.isAwake },
      set: { controller.setAwake($0) }
    )
  }

  private var statusCard: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
      statusRow("Awake", awakeStatus)
      statusRow("バッテリー", controller.power.batteryPercentage.map { "\($0)%" } ?? "利用不可")
      statusRow("電源", controller.power.isOnACPower ? "AC" : "バッテリー")
      statusRow("温度状態", controller.thermalState.displayName)
      statusRow("残り時間", controller.timerRemaining)
    }
    .padding(12)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
  }

  private func confirmAndUninstall() {
    NSApp.activate(ignoringOtherApps: true)
    let confirmation = NSAlert()
    confirmation.alertStyle = .warning
    confirmation.messageText = "Awakeをアンインストールしますか？"
    confirmation.informativeText =
      "Awakeをオフにしてスリープ設定を元に戻し、特権ヘルパーの登録と保存した設定を削除します。最後にAwake.appをゴミ箱に移動して終了します。"
    confirmation.addButton(withTitle: "アンインストール").hasDestructiveAction = true
    confirmation.addButton(withTitle: "キャンセル")
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }

    Task {
      do {
        let sleepStillDisabled = try await controller.uninstall()
        await finishUninstall(sleepStillDisabled: sleepStillDisabled)
      } catch {
        let failure = NSAlert()
        failure.alertStyle = .critical
        failure.messageText = "アンインストールできませんでした"
        failure.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        failure.runModal()
      }
    }
  }

  private func finishUninstall(sleepStillDisabled: Bool) async {
    var lines = ["特権ヘルパーの登録と保存した設定を削除しました。"]
    do {
      _ = try await NSWorkspace.shared.recycle([Bundle.main.bundleURL])
      lines.append("Awake.appをゴミ箱に移動しました。")
    } catch {
      lines.append("Awake.appをゴミ箱に移動できませんでした。Finderで「アプリケーション」フォルダから削除してください。")
    }
    if sleepStillDisabled {
      lines.append(
        "システムのスリープ無効設定（SleepDisabled）が1のままです。Awake以外のツールで設定していなければ、ターミナルで次のコマンドを実行してください。\nsudo pmset -a disablesleep 0"
      )
    }

    let completion = NSAlert()
    completion.messageText = "アンインストールが完了しました"
    completion.informativeText = lines.joined(separator: "\n\n")
    completion.addButton(withTitle: "終了")
    NSApp.activate(ignoringOtherApps: true)
    completion.runModal()
    NSApp.terminate(nil)
  }

  private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "不明"
    let build = info?["CFBundleVersion"] as? String ?? "不明"
    return "バージョン \(version) (\(build))"
  }

  private var awakeStatus: String {
    if controller.isAwake, controller.isTransitioning { return "復旧中…" }
    return controller.isAwake ? "ON" : "OFF"
  }

  private func statusRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .fontWeight(label == "Awake" ? .semibold : .regular)
    }
  }
}
