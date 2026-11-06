import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("bottleneckThresholdGbps") private var thresholdGbps: Double = 36.0
    @AppStorage("bottleneckAlertsEnabled") private var alertsEnabled: Bool = true
    @AppStorage("pollIntervalSeconds") private var pollInterval: Double = 0.5
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Bottleneck alerts", isOn: $alertsEnabled)
                Picker("Refresh rate", selection: $pollInterval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundColor(.red)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bottleneck Alert Threshold")
                        Spacer()
                        Text(String(format: "%.0f Gbps", thresholdGbps))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $thresholdGbps, in: 10...40, step: 1)
                        .disabled(!alertsEnabled)
                    Text("You'll get a notification when total measured throughput crosses this level.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
