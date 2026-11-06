import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
class HardwareManager: ObservableObject {
    static let shared = HardwareManager()
    
    @Published var deviceTrees: [DeviceNode] = []
    @Published var expandedNodes: Set<UUID> = []
    @Published var isScanning = false
    // True during the first scan while the tree is shown but not yet fully enriched, so totals aren't final.
    @Published var isScanningThunderbolt = false
    
    init() {
        // When hosting the unit-test bundle, don't start background scanning/polling: the tests
        // call the scanners directly, and a live polling loop keeps the test host from exiting.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        HardwareWatcher.shared.onHardwareChanged = { [weak self] in
            Task { @MainActor in
                self?.performScan()
            }
        }
        HardwareWatcher.shared.startMonitoring()
        LiveAnalytics.shared.start()
        performScan()
    }

    func performScan() {
        guard !isScanning else { return }
        isScanning = true
        // Only stream a partial tree on the first scan. On rescans, keep showing the current tree
        // and swap in the complete result, rather than flashing a tree missing its Thunderbolt part.
        let streamPartial = deviceTrees.isEmpty
        isScanningThunderbolt = streamPartial

        Task {
            let (scannedTrees, allIDs) = await Task.detached(priority: .userInitiated) { () -> ([DeviceNode], Set<UUID>) in
                // The HardwareScanner is a Struct, rendering it immune to @MainActor inference contamination.
                let scanner = HardwareScanner()
                var partialHandler: (@Sendable ([DeviceNode]) -> Void)? = nil
                if streamPartial {
                    partialHandler = { (partial: [DeviceNode]) in
                        let ids = UIBackgroundWorkers.gatherAllDeviceIDs(from: partial)
                        Task { @MainActor in
                            HardwareManager.shared.deviceTrees = partial
                            HardwareManager.shared.expandedNodes = ids
                        }
                    }
                }
                let trees = scanner.scanForDevices(onPartial: partialHandler)
                let ids = UIBackgroundWorkers.gatherAllDeviceIDs(from: trees)
                return (trees, ids)
            }.value

            // Re-sync with MainActor context
            self.deviceTrees = scannedTrees
            self.expandedNodes = allIDs
            self.isScanning = false
            self.isScanningThunderbolt = false
        }
    }

    // iostat -I only reports its busiest few disks by default, which can silently exclude an
    // idle-looking external drive (e.g. noisy Simulator disk images crowd it out). LiveAnalytics
    // uses this to pass explicit disk names so the ones we actually track always show up.
    func gatherTrackedDiskBSDNames() -> [String] {
        var names: [String] = []
        func walk(_ nodes: [DeviceNode]) {
            for node in nodes {
                if let bsd = node.peripheralDetails?.bsdName, bsd.hasPrefix("disk") {
                    names.append(bsd)
                }
                if let children = node.children { walk(children) }
            }
        }
        walk(deviceTrees)
        return names
    }

    func gatherSystemTotal() -> Double {
        var total = 0.0
        if let bus = deviceTrees.first(where: { $0.name == "Thunderbolt Bus" }), let ports = bus.children {
            for port in ports {
                if let label = port.bandwidthLabel {
                    let parts = label.components(separatedBy: "/")
                    if let valStr = parts.first?.trimmingCharacters(in: .whitespaces) {
                        // Extract numeric value from "10.0 Gbps" or "10.0"
                        let numericOnly = valStr.replacingOccurrences(of: " Gbps", with: "").replacingOccurrences(of: " Gb/s", with: "")
                        if let val = Double(numericOnly) {
                            total += val
                        }
                    }
                }
            }
        }
        return total
    }
    
    func copyMarkdownAction() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        let text = UIBackgroundWorkers.generateHardwareMarkdown(from: deviceTrees)
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Thread-Safe Pure Functions
// Wrapping these in a strict generic struct mathematically prevents Swift 6 from inferring @MainActor from the file's primary class
struct UIBackgroundWorkers {
    static func generateHardwareMarkdown(from nodes: [DeviceNode], depth: Int = 0) -> String {
        var result = ""
        let indent = String(repeating: "  ", count: depth)
        for node in nodes {
            let bwSuffix = node.bandwidthLabel != nil ? " [\(node.bandwidthLabel!)]" : ""
            result += "\(indent)- \(node.name)\(bwSuffix)\n"
            if let children = node.children {
                result += generateHardwareMarkdown(from: children, depth: depth + 1)
            }
        }
        return result
    }
    
    nonisolated static func gatherAllDeviceIDs(from nodes: [DeviceNode]) -> Set<UUID> {
        var ids = Set<UUID>()
        for node in nodes {
            ids.insert(node.id)
            if let children = node.children {
                ids.formUnion(gatherAllDeviceIDs(from: children))
            }
        }
        return ids
    }
}
