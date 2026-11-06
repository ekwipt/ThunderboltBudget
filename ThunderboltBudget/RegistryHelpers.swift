import Foundation

nonisolated struct Accessory: Hashable {
    let name: String
    let speed: String?
}

nonisolated struct PortMapping {
    var uids: Set<String> = []
    var displays: Set<Accessory> = []
}

/// Shared types and pure helpers for the native registry scanners
/// (`NativeRegistryScan`, `NativeThunderboltScanner`, `NativeDisplayScanner`).
nonisolated enum RegistryHelpers {

    /// Result of scanning IORegistry for BSD device identifiers (e.g. "disk4", "en5"),
    /// used to correlate physical devices with live iostat/netstat throughput.
    struct BSDMappingResult {
        /// bsdName → ordered candidate ancestor names, innermost (closest to the actual device,
        /// e.g. "USB 10/100/1000 LAN") first, outermost (e.g. a parent hub chip it's plugged
        /// into) last. Innermost is preferred so traffic attributes to the specific accessory,
        /// not whatever hub happens to share the same ioreg ancestry.
        var candidatesByBSDName: [String: [String]] = [:]
        /// Every physical (non-partition) disk BSD id found, for elimination-based fallback
        /// matching when a storage device has no recognizable product name in its ioreg subtree
        /// (e.g. bare Thunderbolt-tunneled NVMe enclosures show up only as their raw PCIe chain).
        var allPhysicalDisks: Set<String> = []
    }

    static func isPhysicalDisk(_ bsdName: String) -> Bool {
        guard bsdName.hasPrefix("disk") else { return false }
        let rest = bsdName.dropFirst(4)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }

    // Ancestor names that are internal IOKit/driver plumbing, not a real product name — matching
    // against these causes false positives, since the same generic label (e.g. "USB3.0 Hub") is
    // reused across many unrelated physical devices system-wide.
    static func isRealProductName(_ name: String) -> Bool {
        if name.hasPrefix("Apple") || name.hasPrefix("IO") { return false }
        let generic: Set<String> = ["USB2.0 Hub", "USB2.1 Hub", "USB3.0 Hub", "USB3.1 Hub", "Hub Feature Controller", "Media"]
        if generic.contains(name) { return false }
        return true
    }

    static func bcdToVersionString(_ value: Int) -> String {
        let major = (value >> 8) & 0xFF
        let minor = (value & 0xFF) >> 4
        return "\(major).\(minor)"
    }

    static func usbSpeedString(_ speed: Int) -> String {
        switch speed {
        case 0: return "1.5 Mbps (Low Speed)"
        case 1: return "12 Mbps (Full Speed)"
        case 2: return "480 Mbps (High Speed)"
        case 3: return "5 Gbps (SuperSpeed)"
        case 4: return "10 Gbps (SuperSpeedPlus)"
        case 5: return "20 Gbps (SuperSpeedPlusX2)"
        default: return "Unknown"
        }
    }
}
