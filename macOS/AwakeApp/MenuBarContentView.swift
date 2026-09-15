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
          Text(appVersion)
            .textSelection(.enabled)
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
