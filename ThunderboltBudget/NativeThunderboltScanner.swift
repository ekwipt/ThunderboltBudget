import Foundation
import IOKit

/// Builds the Thunderbolt device tree straight from the IOKit registry, producing the same
/// `SPNode` shape `system_profiler SPThunderboltDataType` does so the rest of the pipeline is unchanged.
/// Runs in milliseconds instead of ~16 s, and needs no subprocess (App Sandbox friendly).
nonisolated enum NativeThunderboltScanner {

    static func scan() -> [SPNode] {
        let controllers = IOKitRegistry.services(matchingClass: "IOThunderboltController")
        defer { IOKitRegistry.release(controllers) }

        var roots: [SPNode] = []
        for controller in controllers {
            let kids = IOKitRegistry.children(of: controller)
            defer { IOKitRegistry.release(kids) }
            let domainUUID = kids.first(where: { $0.className.hasPrefix("IOThunderboltLocalNode") })?.string("Domain UUID")

            // The host (depth 0) switch hangs beneath the controller's host-interface port.
            for port in kids where port.className == "IOThunderboltPort" {
                let below = IOKitRegistry.children(of: port)
                defer { IOKitRegistry.release(below) }
                for sw in below where sw.className.hasPrefix("IOThunderboltSwitch") {
                    if let node = buildNode(sw, isHost: true, domainUUID: domainUUID) { roots.append(node) }
                }
            }
        }
        // Stable order by bus number (host router ID).
        return roots.sorted { ($0._name ?? "") < ($1._name ?? "") }
    }

    // MARK: - Tree construction

    private static func buildNode(_ sw: IORegistryNode, isHost: Bool, domainUUID: String?, upstreamPort: IORegistryNode? = nil) -> SPNode? {
        let ports = IOKitRegistry.children(of: sw).filter { $0.className == "IOThunderboltPort" }
        defer { IOKitRegistry.release(ports) }

        // Child switches hang beneath connected ports (via the peer port).
        var childNodes: [SPNode] = []
        var portsWithDevice = Set<Int>()
        for port in ports {
            for (child, peer) in connectedSwitches(below: port) {
                defer { IOObjectRelease(child.entry) }
                if let n = buildNode(child, isHost: false, domainUUID: nil, upstreamPort: peer) {
                    childNodes.append(n)
                    if let num = port.int("Port Number") { portsWithDevice.insert(num) }
                }
            }
        }

        var node = SPNode()
        let routerID = sw.int("Router ID") ?? 0
        let vendorName = sw.string("Device Vendor Name")
        let modelName = sw.string("Device Model Name")

        node._name = isHost ? "thunderboltusb4_bus_\(routerID)" : (modelName ?? "Thunderbolt Device")
        node.device_name_key = isHost ? deviceModelDisplayName() : modelName
        node.vendor_name_key = vendorName
        // system_profiler lists a host with nothing plugged in as a bare bus: no UID or route string.
        if !isHost || !childNodes.isEmpty {
            node.switch_uid_key = sw.uint64("UID").map { String(format: "0x%016llX", $0) }
            node.route_string_key = sw.uint64("Route String").map { String($0, radix: 16, uppercase: true) }
        }
        node.domain_uuid_key = domainUUID
        node._items = childNodes.isEmpty ? nil : childNodes

        if !isHost {
            node.device_id_key = sw.int("Device Model ID").map { "0x" + String($0, radix: 16, uppercase: true) }
            node.device_revision_key = sw.int("Device Model Revision").map { "0x" + String($0, radix: 16, uppercase: true) }
            node.vendor_id_key = sw.int("Device Vendor ID").map { "0x" + String($0, radix: 16, uppercase: true) }
            // Thunderbolt Version 32 (0x20) is the USB4 v1 router architecture.
            node.mode_key = (sw.int("Thunderbolt Version") ?? 0) >= 32 ? "usb_four" : "tb3"
        }

        // Receptacle tags come from the lane-0 adapter ports (the odd-numbered port of each lane pair).
        let lane0 = ports.filter { $0.int("Adapter Type") == 1 && $0.int("Lane") == 1 }
            .sorted { ($0.int("Port Number") ?? 0) < ($1.int("Port Number") ?? 0) }

        if isHost {
            if let port = lane0.first(where: { $0.int("Port Number") == 1 }), portsWithDevice.contains(1) {
                var tag = makeTag(port, connected: true)
                tag.receptacle_id_key = port.string("Socket ID")
                node.receptacle_1_tag = tag
            }
        } else {
            // Upstream link: the peer port this switch hangs beneath.
            if let up = upstreamPort { node.receptacle_upstream_ambiguous_tag = makeTag(up, connected: true) }
            // Downstream ports in order become receptacle_2…4.
            let downstream = lane0.filter { $0.int("Port Number") != sw.int("Upstream Port Number") }
            for (index, port) in downstream.prefix(3).enumerated() {
                let connected = portsWithDevice.contains(port.int("Port Number") ?? -1)
                let tag = makeTag(port, connected: connected)
                switch index {
                case 0: node.receptacle_2_tag = tag
                case 1: node.receptacle_3_tag = tag
                default: node.receptacle_4_tag = tag
                }
            }
        }
        return node
    }

    /// A connected device's switch sits beneath the local port's peer port, so descend through
    /// port-to-port links until switches are found. Returns each switch with the peer port that
    /// is its upstream link; only links that are up count as connected. Caller releases the nodes.
    private static func connectedSwitches(below port: IORegistryNode) -> [(sw: IORegistryNode, upstream: IORegistryNode)] {
        var found: [(sw: IORegistryNode, upstream: IORegistryNode)] = []
        for child in IOKitRegistry.children(of: port) {
            if child.className.hasPrefix("IOThunderboltSwitch") {
                // `port` is this switch's upstream (peer) port.
                if isLinkUp(port) { found.append((child, port)) } else { IOObjectRelease(child.entry) }
            } else if child.className == "IOThunderboltPort" {
                found.append(contentsOf: connectedSwitches(below: child))
                IOObjectRelease(child.entry)
            } else {
                IOObjectRelease(child.entry)
            }
        }
        return found
    }

    private static func isLinkUp(_ port: IORegistryNode) -> Bool {
        (port.int("Current Link Width") ?? 0) > 0 && (port.int("Current Link Speed") ?? 0) > 0
    }

    // MARK: - Derived values

    private static func makeTag(_ port: IORegistryNode, connected: Bool) -> ReceptacleTag {
        ReceptacleTag(
            current_speed_key: speedLabel(port, connected: connected),
            link_status_key: nil,
            micro_version_key: microVersion(port.int("Micro Version")),
            receptacle_status_key: connected ? "receptacle_connected" : "receptacle_no_devices_connected"
        )
    }

    /// Per-lane Gb/s from the USB4 link-speed bitfield (bit 3 = Gen2 10 Gb/s, bit 2 = Gen3 20 Gb/s).
    private static func laneGbps(_ code: Int) -> Int {
        if code & 0x4 != 0 { return 20 }
        if code & 0x8 != 0 { return 10 }
        return 0
    }

    private static func speedLabel(_ port: IORegistryNode, connected: Bool) -> String? {
        if connected {
            let lanes = port.int("Current Link Width") ?? 0
            let per = laneGbps(port.int("Current Link Speed") ?? 0)
            guard lanes > 0, per > 0 else { return nil }
            return "\(lanes * per) Gb/s"
        }
        // Not connected: advertise the maximum the port supports.
        let lanes = max(port.int("Supported Link Width") ?? 0, 1)
        // Supported speed lists every speed it can do; the fastest wins.
        let per = max(laneGbps(port.int("Supported Link Speed") ?? 0), laneGbps(port.int("Target Link Speed") ?? 0))
        guard per > 0 else { return nil }
        return "Up to \(lanes * per) Gb/s"
    }

    private static func microVersion(_ value: Int?) -> String? {
        guard let v = value else { return nil }
        return String(format: "%x.%x.%x", (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// "MacBook Pro" style marketing name, as `system_profiler` reports for the host.
    private static func deviceModelDisplayName() -> String? {
        let nodes = IOKitRegistry.services(matchingClass: "IOPlatformExpertDevice")
        defer { IOKitRegistry.release(nodes) }
        guard let n = nodes.first else { return nil }
        if let data = n.data("product-name") ?? n.data("model") {
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return nil
    }
}
