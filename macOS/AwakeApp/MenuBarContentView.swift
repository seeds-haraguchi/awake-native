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
          Text("Keep your Mac awake, even with the lid closed.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("Awake", isOn: awakeBinding)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(controller.isTransitioning)
      }

      statusCard

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Timer")
          Picker("Timer", selection: $controller.timerPreset) {
            ForEach(TimerPreset.allCases) { preset in
              Text(preset.title).tag(preset)
            }
          }
          .labelsHidden()
        }

        if controller.timerPreset == .custom {
          GridRow {
            Text("Duration")
            Stepper(
              "\(controller.customTimerMinutes) minutes",
              value: $controller.customTimerMinutes,
              in: 1...(7 * 24 * 60)
            )
          }
        }

        GridRow {
          Text("Battery Safety")
          Picker("Battery Safety", selection: $controller.batteryThreshold) {
            ForEach(BatterySafetyThreshold.allCases) { threshold in
              Text(threshold.title).tag(threshold)
            }
          }
          .labelsHidden()
        }

        GridRow {
          Text("Thermal Safety")
          Toggle("Thermal Safety", isOn: $controller.thermalSafetyEnabled)
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
            Button("Open Login Items Settings") {
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
        Text("Battery Safety is ignored while connected to AC power.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Quit Awake") {
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
      statusRow("Battery", controller.power.batteryPercentage.map { "\($0)%" } ?? "N/A")
      statusRow("Power", controller.power.isOnACPower ? "AC" : "Battery")
      statusRow("Thermal", controller.thermalState.displayName)
      statusRow("Timer remaining", controller.timerRemaining)
    }
    .padding(12)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
  }

  private var awakeStatus: String {
    if controller.isAwake, controller.isTransitioning { return "RESTORING…" }
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
