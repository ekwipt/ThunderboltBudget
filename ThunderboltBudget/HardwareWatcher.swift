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
    private var lastDiskMBByDevice: [String: Double] = [:]
    private var lastNetBytesByInterface: [String: Double] = [:]
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
        // returned yet, letting polls overlap and race on lastDiskMBByDevice/lastPollDate, which
        // is what was producing bogus near-zero throughput readings.
        pollLoopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollMetrics()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func pollMetrics() async {
        let trackedDisks = await MainActor.run { HardwareManager.shared.gatherTrackedDiskBSDNames() }
        // Run both shell calls concurrently instead of back-to-back, halving the wall-clock
        // cost of each poll so it reliably completes within the 0.5s cadence.
        async let diskMBByDevice = fetchExternalDiskCumulativeMB(tracking: trackedDisks)
        async let netBytesByInterface = fetchExternalNetworkCumulativeBytes()
        let (diskResult, netResult) = await (diskMBByDevice, netBytesByInterface)
        let displayGbps = await MainActor.run { fetchStaticDisplayGbps() } // Already calculated in HardwareManager

        await MainActor.run {
            let diskMBByDevice = diskResult
            let netBytesByInterface = netResult
            let now = Date()
            let elapsed = now.timeIntervalSince(lastPollDate)

            // Guard against a near-zero interval (e.g. two ticks landing back-to-back)
            // producing a divide-by-near-zero spike in the rate.
            if isFirstTick || elapsed < 0.05 {
                isFirstTick = false
            } else {
                var newLiveByBSDName: [String: Double] = [:]
                var diskGbps = 0.0
                for (device, cumulativeMB) in diskMBByDevice {
                    let deltaMB = max(0, cumulativeMB - (lastDiskMBByDevice[device] ?? cumulativeMB))
                    let gbps = (deltaMB * 8) / 1000.0 / elapsed
                    newLiveByBSDName[device] = gbps
                    diskGbps += gbps
                }
                var netGbps = 0.0
                for (iface, cumulativeBytes) in netBytesByInterface {
                    let deltaBytes = max(0, cumulativeBytes - (lastNetBytesByInterface[iface] ?? cumulativeBytes))
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

            lastDiskMBByDevice = diskMBByDevice
            lastNetBytesByInterface = netBytesByInterface
            lastPollDate = now
        }
    }

    private var lastNotificationTime = Date.distantPast
    // The consumption value we last actually notified about, so we can tell a genuinely new
    // reading from noise around the same steady-state bottleneck. nil means no active episode.
    private var lastNotifiedConsumption: Double?

    private static let bottleneckThreshold = 36.0
    // Must drop meaningfully below the trigger threshold (not just tick under it once) before a
    // later crossing counts as a fresh episode -- avoids flapping when consumption hovers near 36.
    private static let bottleneckClearThreshold = 34.0
    private static let significantChangeGbps = 3.0
    private static let minNotificationInterval: TimeInterval = 120

    private func evaluateBottleneck(consumption: Double) {
        if consumption < Self.bottleneckClearThreshold {
            lastNotifiedConsumption = nil
            return
        }
        guard consumption >= Self.bottleneckThreshold else { return }

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

    private func fetchExternalDiskCumulativeMB(tracking trackedDisks: [String]) async -> [String: Double] {
        // Without explicit disk names, iostat -I only reports its busiest few disks by default —
        // an idle-looking external drive can get silently crowded out (e.g. by noisy Simulator
        // disk images), even mid-transfer. Naming the disks we actually track guarantees they appear.
        let diskArgs = trackedDisks.filter { $0.hasPrefix("disk") && $0.dropFirst(4).allSatisfy { $0.isNumber } }
        let command = diskArgs.isEmpty ? "iostat -I" : "iostat -I \(diskArgs.joined(separator: " "))"
        let output = await runShell(command)
        var result: [String: Double] = [:]

        let lines = output.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return result }

        // Find columns dynamically
        let headers = lines[0].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let stats = lines[2].components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        for (idx, disk) in headers.enumerated() {
            if disk == "disk0" { continue } // Ignore internal NVMe

            // iostat pairs stats in blocks of 3: KB/t, xfrs, MB
            let mbIndex = (idx * 3) + 2
            if mbIndex < stats.count, let val = Double(stats[mbIndex]) {
                result[disk] = val
            }
        }
        return result
    }

    private func fetchExternalNetworkCumulativeBytes() async -> [String: Double] {
        let output = await runShell("netstat -ib")
        var result: [String: Double] = [:]

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard cols.count > 10 else { continue }

            let name = cols[0]
            // We want external physical adapters (usually enX where X is not 0 (Wi-Fi)).
            // Ignore loopback (lo0), awdl, llw, bridge, utun
            if name == "en0" || name.hasPrefix("lo") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("bridge") || name.hasPrefix("utun") {
                continue
            }

            // netstat -ib lists one row per address family (Link#, inet, inet6) for the same
            // interface; they report the same cumulative counters, so take the max instead of
            // summing to avoid inflating a single interface's traffic 2-3x.
            if let ibytes = Double(cols[6]), let obytes = Double(cols[9]) {
                result[name] = max(result[name] ?? 0, ibytes + obytes)
            }
        }

        return result
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

    private func runShell(_ command: String) async -> String {
        return await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardOutput = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                return ""
            }
        }.value
    }
}
