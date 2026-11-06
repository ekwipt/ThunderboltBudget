import SwiftUI
import Charts

struct MenuBarView: View {
    @ObservedObject var manager = HardwareManager.shared
    @ObservedObject var analytics = LiveAnalytics.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let ports = manager.deviceTrees.first { $0.name == "Thunderbolt Bus" }?.children ?? []
            
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
                            
                            if let live = analytics.liveGbps(for: port) {
                                Text(String(format: "%.2f Gbps live", live))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }

                            if let bw = port.bandwidthLabel {
                                Text(bw)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(pillColor(for: port))
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }
                        }
                        if let ratio = port.bandwidthRatio {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.2))
                                    
                                    Rectangle()
                                        .fill(pillColor(for: port))
                                        .frame(width: max(0, min(CGFloat(ratio), 1.0) * geo.size.width))
                                }
                            }
                            .frame(height: 3)
                            .cornerRadius(1.5)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            
            if !ports.isEmpty {
                TrafficSparkline(samples: analytics.totalTrafficGbps)
            }

            HStack {
                Text(String(format: "Total Consumption: %.1f Gbps", manager.gatherSystemTotal()))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
    
    private func pillColor(for node: DeviceNode) -> Color {
        guard let ratio = node.bandwidthRatio else {
            return Color.blue.opacity(0.8)
        }
        if ratio >= 0.80 { return Color.red }
        else if ratio >= 0.50 { return Color.orange }
        else { return Color.green }
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
