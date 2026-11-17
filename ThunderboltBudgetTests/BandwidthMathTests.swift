import Testing
import Foundation
@testable import ThunderboltBudget

struct BandwidthMathTests {

    @Test func parsesBandwidthLabels() {
        #expect(UIBackgroundWorkers.gbps(fromLabel: "12.5 Gbps") == 12.5)
        #expect(UIBackgroundWorkers.gbps(fromLabel: "40 Gb/s") == 40)
        #expect(UIBackgroundWorkers.gbps(fromLabel: "480 Mbps") == 0.48)
        #expect(UIBackgroundWorkers.gbps(fromLabel: "Up to 40 Gb/s") == nil)
    }

    @Test func portCapacityComesFromLabel() {
        #expect(UIBackgroundWorkers.capacityGbps(of: DeviceNode(name: "Port", bandwidthLabel: "12.0 / 80 Gbps")) == 80)
        #expect(UIBackgroundWorkers.capacityGbps(of: DeviceNode(name: "Port", bandwidthLabel: "12.0 / 40 Gbps")) == 40)
        #expect(UIBackgroundWorkers.capacityGbps(of: DeviceNode(name: "Port")) == 40)
    }

    /// Regression: an idle 40 Gb/s SSD's link speed must not count as live traffic -- only the
    /// display's estimated video bandwidth does.
    @Test func displayEstimateIgnoresLinkSpeeds() {
        let ssd = DeviceNode(name: "TB4 SSD", bandwidthLabel: "40 Gb/s")
        let display = DeviceNode(name: "Studio Display (5120 x 2880 @ 60Hz)", bandwidthLabel: "25.5 Gbps", displayDetails: DisplayDetails())
        let dock = DeviceNode(name: "Dock", bandwidthLabel: "40 Gb/s", children: [ssd, display])
        let port = DeviceNode(name: "Thunderbolt Port 1", bandwidthLabel: "65.5 / 40 Gbps", children: [dock])

        #expect(UIBackgroundWorkers.estimatedDisplayGbps(in: [port]) == 25.5)
        #expect(UIBackgroundWorkers.estimatedDisplayGbps(in: [DeviceNode(name: "Port", children: [ssd])]) == 0)
    }
}
