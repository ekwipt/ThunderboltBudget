import SwiftUI

struct SettingsView: View {
    @AppStorage("bottleneckThresholdGbps") private var thresholdGbps: Double = 36.0

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bottleneck Alert Threshold")
                        Spacer()
                        Text(String(format: "%.0f Gbps", thresholdGbps))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $thresholdGbps, in: 10...40, step: 1)
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
