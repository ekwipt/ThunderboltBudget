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

    @Test func portCapacityDefaultsTo40() {
        var tb5 = DeviceNode(name: "Port")
        tb5.capacityGbps = 80
        #expect(UIBackgroundWorkers.capacityGbps(of: tb5) == 80)
        #expect(UIBackgroundWorkers.capacityGbps(of: DeviceNode(name: "Port")) == 40)
    }

    /// Regression: an idle 40 Gb/s SSD's link speed must not count as live traffic -- only the
    /// display's estimated video bandwidth does.
    @Test func displayEstimateIgnoresLinkSpeeds() {
        let ssd = DeviceNode(name: "TB4 SSD", bandwidthLabel: "40 Gb/s")
        let display = DeviceNode(name: "Studio Display (5120 x 2880 @ 60Hz)", bandwidthLabel: "25.5 Gbps", displayDetails: DisplayDetails())
        let dock = DeviceNode(name: "Dock", bandwidthLabel: "40 Gb/s", children: [ssd, display])
        let port = DeviceNode(name: "Thunderbolt Port 1", children: [dock])

        #expect(UIBackgroundWorkers.estimatedDisplayGbps(in: [port]) == 25.5)
        #expect(UIBackgroundWorkers.estimatedDisplayGbps(in: [DeviceNode(name: "Port", children: [ssd])]) == 0)
    }

    /// Regression: an idle port with a USB4 drive (40 Gb/s link) and a USB 2 device behind a hub
    /// must read as idle, not "40.5 / 40 Gbps" -- link speeds are shared, not consumed.
    @Test @MainActor func idlePortWithFastDrivesReadsZero() {
        let drive = DeviceNode(name: "OWC Express 1M2", bandwidthLabel: "40 Gb/s")
        let audio = DeviceNode(name: "Fresco Logic USB", bandwidthLabel: "480 Mb/s")
        let hub = DeviceNode(name: "Sonnet Hub", bandwidthLabel: "40 Gb/s", children: [drive, audio])
        var port = DeviceNode(name: "Right Port", children: [hub])
        port.capacityGbps = 40
        #expect(LiveAnalytics.shared.portUsageGbps(port) == 0)
    }

    @Test func usageColorThresholds() {
        #expect(UIBackgroundWorkers.usageColorLevel(ratio: 0.1) == 0)
        #expect(UIBackgroundWorkers.usageColorLevel(ratio: 0.5) == 1)
        #expect(UIBackgroundWorkers.usageColorLevel(ratio: 0.85) == 2)
    }
}
