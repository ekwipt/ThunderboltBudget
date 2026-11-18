import SwiftUI
import Charts

struct MenuBarView: View {
    @ObservedObject var manager = HardwareManager.shared
    @ObservedObject var analytics = LiveAnalytics.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let ports = manager.thunderboltPorts
            
            if ports.isEmpty {
                Text(manager.isScanning ? "Scanning..." : "No Thunderbolt Ports Active")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(ports) { port in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.blue)
                            Text(port.name)
                                .font(.system(.body, design: .rounded))
                            
                            Spacer(minLength: 20)
                            
                            PortUsagePill(usage: analytics.portUsageGbps(port), capacity: capacity(port))
                        }
                        PortUsageBar(usage: analytics.portUsageGbps(port), capacity: capacity(port), height: 3)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            
            if !ports.isEmpty {
                TrafficSparkline(samples: analytics.totalTrafficGbps)
            }

            HStack {
                Button("Open Thunderbolt Budget") {
                    // The popover doesn't activate the app, so bring it forward first or the
                    // window opens behind whatever app is frontmost.
                    NSApp.activate()
                    openWindow(id: ThunderboltBudgetApp.mainWindowID)
                }
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 380)
    }
    
    private func capacity(_ port: DeviceNode) -> Double {
        UIBackgroundWorkers.capacityGbps(of: port)
    }
}


/// Compact last-minute total-traffic trend for the menu bar popover.
struct TrafficSparkline: View {
    let samples: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Live throughput")
                Spacer()
                Text(String(format: "%.2f Gbps", samples.last ?? 0))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                    AreaMark(x: .value("Sample", index), y: .value("Gbps", value))
                        .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.5), .blue.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Sample", index), y: .value("Gbps", value))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(40.0, (samples.max() ?? 0) + 2))
            .frame(height: 36)
        }
    }
}
