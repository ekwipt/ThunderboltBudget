import Foundation
import AppKit
import IOKit
import IOKit.usb
import Combine
import SwiftUI
import UserNotifications

private func usbCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) -> Void {
    while IOIteratorNext(iterator) != 0 {}
    HardwareWatcher.shared.triggerUpdate()
}

private func displayCallback(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags, userInfo: UnsafeMutableRawPointer?) -> Void {
    HardwareWatcher.shared.triggerUpdate()
}

class HardwareWatcher {
    static let shared = HardwareWatcher()
    
    var onHardwareChanged: (() -> Void)?
    
    private var notifyPort: IONotificationPortRef?
    private var debounceTimer: Timer?
    
    func startMonitoring() {
        if notifyPort != nil { return } // Reject duplicate starts
        
        // kIOMainPortDefault is available on all Apple Silicon targets
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else { return }
        
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        
        // Register for display reconfiguration (works across all macOS versions)
        CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
        
        // macOS Sequoia (15+) renamed IOUSBDevice -> IOUSBHostDevice.
        // We register BOTH class names so the app works on Ventura, Sonoma, AND Sequoia.
        let usbClasses = ["IOUSBHostDevice", "IOUSBDevice"]
        for className in usbClasses {
            if let match = IOServiceMatching(className) {
                var addedIter: io_iterator_t = 0
                var removedIter: io_iterator_t = 0
                
                IOServiceAddMatchingNotification(port, kIOPublishNotification,
                    match as CFDictionary, usbCallback, nil, &addedIter)
                while IOIteratorNext(addedIter) != 0 {}
                
                if let match2 = IOServiceMatching(className) {
                    IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                        match2 as CFDictionary, usbCallback, nil, &removedIter)
                    while IOIteratorNext(removedIter) != 0 {}
                }
            }
        }
        
        // Also monitor Thunderbolt device attach/detach directly (missed entirely before)
        if let tbMatch = IOServiceMatching("IOThunderboltDevice") {
            var tbAddedIter: io_iterator_t = 0
            var tbRemovedIter: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, kIOPublishNotification,
                tbMatch as CFDictionary, usbCallback, nil, &tbAddedIter)
            while IOIteratorNext(tbAddedIter) != 0 {}
            
            if let tbMatch2 = IOServiceMatching("IOThunderboltDevice") {
                IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                    tbMatch2 as CFDictionary, usbCallback, nil, &tbRemovedIter)
                while IOIteratorNext(tbRemovedIter) != 0 {}
            }
        }
    }
    
    func triggerUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                self?.onHardwareChanged?()
            }
        }
    }
}

class LiveAnalytics: ObservableObject {
    static let shared = LiveAnalytics()
    
    // 120 samples at the 0.5s poll interval keeps the chart's window at 60 seconds.
    @Published var totalTrafficGbps: [Double] = Array(repeating: 0.0, count: 120)
    // Live, real-time throughput per BSD identifier (e.g. "disk4", "en5"), updated every second.
    // Distinct from the static per-port "budget" bars: this is measured, not negotiated link capacity.
    @Published var liveGbpsByBSDName: [String: Double] = [:]

    private var pollLoopTask: Task<Void, Never>?

    // Track previous cumulative totals per device to calculate deltas
    private var lastDiskBytesByDevice: [String: Double] = [:]
    private var lastNetCountersByInterface: [String: NativeLiveStats.NetCounters] = [:]
    private var lastPollDate: Date = Date()

    // We only begin calculating differences after the first tick finishes storing state
    private var isFirstTick = true

    func start() {
        if pollLoopTask != nil { return }

        // Request Notification Permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted { print("Notifications authorized") }
        }

        // A self-rescheduling loop (rather than a repeating Timer) guarantees each poll fully
        // finishes — including both shell calls — before the next one starts. A plain repeating
        // Timer would fire every 0.5s regardless of whether the prior poll's subprocesses had
        // returned yet, letting polls overlap and race on lastDiskBytesByDevice/lastPollDate, which
        // is what was producing bogus near-zero throughput readings.
        pollLoopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollMetrics()
                let interval = UserDefaults.standard.double(forKey: "pollIntervalSeconds")
                let seconds = interval > 0 ? interval : 0.5
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    private func pollMetrics() async {
        let trackedDisks = await MainActor.run { HardwareManager.shared.gatherTrackedDiskBSDNames() }
        // Run both shell calls concurrently instead of back-to-back, halving the wall-clock
        // cost of each poll so it reliably completes within the 0.5s cadence.
        let (diskResult, netResult) = await Task.detached(priority: .userInitiated) {
            (Self.readDiskBytes(tracking: trackedDisks), Self.readNetworkCounters())
        }.value
        let displayGbps = await MainActor.run { fetchStaticDisplayGbps() } // Already calculated in HardwareManager

        await MainActor.run {
            let diskBytesByDevice = diskResult
            let netCountersByInterface = netResult
            let now = Date()
            let elapsed = now.timeIntervalSince(lastPollDate)

            // Guard against a near-zero interval (e.g. two ticks landing back-to-back)
            // producing a divide-by-near-zero spike in the rate.
            if isFirstTick || elapsed < 0.05 {
                isFirstTick = false
            } else {
                var newLiveByBSDName: [String: Double] = [:]
                var diskGbps = 0.0
                for (device, cumulativeBytes) in diskBytesByDevice {
                    let deltaBytes = max(0, cumulativeBytes - (lastDiskBytesByDevice[device] ?? cumulativeBytes))
                    let gbps = (deltaBytes * 8) / 1_000_000_000.0 / elapsed
                    newLiveByBSDName[device] = gbps
                    diskGbps += gbps
                }
                var netGbps = 0.0
                for (iface, counters) in netCountersByInterface {
                    let previous = lastNetCountersByInterface[iface] ?? counters
                    let deltaBytes = Double(NativeLiveStats.counterDelta(from: previous.inBytes, to: counters.inBytes)
                                            + NativeLiveStats.counterDelta(from: previous.outBytes, to: counters.outBytes))
                    let gbps = (deltaBytes * 8) / 1_000_000_000.0 / elapsed
                    newLiveByBSDName[iface] = gbps
                    netGbps += gbps
                }
                liveGbpsByBSDName = newLiveByBSDName

                let newTotal = diskGbps + netGbps + displayGbps

                totalTrafficGbps.append(newTotal)
                if totalTrafficGbps.count > 120 {
                    totalTrafficGbps.removeFirst()
                }

                evaluateBottleneck(consumption: newTotal)
            }

            lastDiskBytesByDevice = diskBytesByDevice
            lastNetCountersByInterface = netCountersByInterface
            lastPollDate = now
        }
    }

    private var lastNotificationTime = Date.distantPast
    // The consumption value we last actually notified about, so we can tell a genuinely new
    // reading from noise around the same steady-state bottleneck. nil means no active episode.
    private var lastNotifiedConsumption: Double?

    // User-configurable via Settings; 36 Gbps matches this system's negotiated Thunderbolt link cap.
    private var bottleneckThreshold: Double {
        let stored = UserDefaults.standard.double(forKey: "bottleneckThresholdGbps")
        return stored > 0 ? stored : 36.0
    }
    // Must drop meaningfully below the trigger threshold (not just tick under it once) before a
    // later crossing counts as a fresh episode -- avoids flapping when consumption hovers near the line.
    private var bottleneckClearThreshold: Double { bottleneckThreshold - 2.0 }
    private static let significantChangeGbps = 3.0
    private static let minNotificationInterval: TimeInterval = 120

    private func evaluateBottleneck(consumption: Double) {
        // Alerts default to on; only an explicit false in Settings disables them.
        if UserDefaults.standard.object(forKey: "bottleneckAlertsEnabled") as? Bool == false { return }
        if consumption < bottleneckClearThreshold {
            lastNotifiedConsumption = nil
            return
        }
        guard consumption >= bottleneckThreshold else { return }

        let isNewEpisode = lastNotifiedConsumption == nil
        let changedSignificantly = lastNotifiedConsumption.map { abs(consumption - $0) >= Self.significantChangeGbps } ?? true
        guard isNewEpisode || changedSignificantly else { return }
        guard Date().timeIntervalSince(lastNotificationTime) > Self.minNotificationInterval else { return }

        lastNotificationTime = Date()
        lastNotifiedConsumption = consumption
        triggerBottleneckWarning(consumption: consumption)
    }

    private func triggerBottleneckWarning(consumption: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Bandwidth Bottleneck Detected"
        content.body = String(format: "Your Thunderbolt bus is currently pushing %.1f Gbps. Consider moving a high-bandwidth device to a separate physical port cluster on your Mac for optimal performance.", consumption)
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Cumulative bytes for the physical disks we track (never the internal boot disk).
    /// Only disks named in `trackedDisks` count, so noisy unrelated volumes (e.g. Simulator
    /// disk images) can't inflate the Thunderbolt total.
    nonisolated private static func readDiskBytes(tracking trackedDisks: [String]) -> [String: Double] {
        let wanted = Set(trackedDisks.filter { $0.hasPrefix("disk") && $0.dropFirst(4).allSatisfy { $0.isNumber } })
        guard !wanted.isEmpty else { return [:] }
        return NativeLiveStats.diskCumulativeBytes().filter { wanted.contains($0.key) && $0.key != "disk0" }
    }

    /// External physical adapters only (usually enX where X is not 0, which is Wi-Fi).
    /// Ignores loopback, awdl, llw, bridge and utun.
    nonisolated private static func readNetworkCounters() -> [String: NativeLiveStats.NetCounters] {
        NativeLiveStats.networkCumulativeBytes().filter { name, _ in
            !(name == "en0" || name.hasPrefix("lo") || name.hasPrefix("awdl") || name.hasPrefix("llw")
              || name.hasPrefix("bridge") || name.hasPrefix("utun"))
        }
    }

    @MainActor
    private func fetchStaticDisplayGbps() -> Double {
        // Find displays in the tree and sum their mathematically hardcoded link bandwidth
        return HardwareManager.shared.gatherSystemTotal() 
    }
    
    // Live measured throughput for a device (if it has a bsdName) or the sum across
    // its subtree (if it's a hub/port). Returns nil when no descendant has live data at all,
    // so nodes unrelated to storage/network (displays, HID devices, generic hubs) show nothing.
    func liveGbps(for node: DeviceNode) -> Double? {
        if let bsdName = node.peripheralDetails?.bsdName {
            return liveGbpsByBSDName[bsdName] ?? 0
        }
        guard let children = node.children else { return nil }
        var total = 0.0
        var foundAny = false
        for child in children {
            if let value = liveGbps(for: child) {
                total += value
                foundAny = true
            }
        }
        return foundAny ? total : nil
    }
}
