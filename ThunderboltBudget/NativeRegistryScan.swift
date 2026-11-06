import Foundation
import IOKit

/// Everything the app used to scrape out of `ioreg -l` text, computed in ONE native registry walk:
/// USB accessory ↔ hub-UID mappings, USB device details, BSD-name ↔ device mappings,
/// Display Stream Compression and per-display details. Matching rules mirror the previous text
/// parsers (`RegistryHelpers`) but operate on registry properties instead of text lines.
nonisolated struct NativeRegistrySnapshot {
    var displayMappings: [String: [Accessory]] = [:]
    var usbDetails: [String: PeripheralDetails] = [:]
    var bsdMappings = RegistryHelpers.BSDMappingResult()
    var dscDisplayNames: Set<String> = []
    var displayDetails: [String: DisplayDetails] = [:]
}

nonisolated enum NativeRegistryScan {

    static func scan() -> NativeRegistrySnapshot {
        var snapshot = NativeRegistrySnapshot()

        var portMaps: [String: PortMapping] = [:]
        var currentDisplayName = ""
        var currentDetails = emptyDetails()

        IORegistryWalker.walk { node, path in
            collectAccessories(node, path, &portMaps)
            collectUSBDetails(node, &snapshot.usbDetails)
            collectBSD(node, path, &snapshot.bsdMappings)
            collectDSC(node, path, &snapshot.dscDisplayNames)
            collectDisplayDetails(node, &currentDisplayName, &currentDetails, &snapshot.displayDetails)
        }
        if !currentDisplayName.isEmpty { snapshot.displayDetails[currentDisplayName] = currentDetails }

        var uidToDisplays: [String: [Accessory]] = [:]
        for mapping in portMaps.values {
            let stable = mapping.displays.sorted { ($0.name, $0.speed ?? "") < ($1.name, $1.speed ?? "") }
            for uid in mapping.uids { uidToDisplays[uid] = stable }
        }
        snapshot.displayMappings = uidToDisplays
        return snapshot
    }

    // MARK: - USB accessories per physical port (was RegistryHelpers.parseOutput)

    private static func collectAccessories(_ node: IORegistryNode, _ path: [String], _ portMaps: inout [String: PortMapping]) {
        let productName = node.string("ProductName") ?? node.string("Product Name") ?? node.string("USB Product Name")
        let metadata = node.dict("Metadata")
        guard productName != nil || metadata != nil else { return }

        // Nearest physical port in the ancestry; the last matching ancestor wins.
        // Apple Silicon tunnels USB through built-in XHCI controllers (usb-drdX), independent of Port-USB-C.
        var port: String? = nil
        for name in path {
            if name.contains("Port-USB-C") {
                port = name
            } else if let drdRange = name.range(of: "usb-drd") {
                let digits = name[drdRange.upperBound...].prefix(while: { $0.isNumber })
                if let n = Int(digits) { port = "Port-USB-C@\(n + 1)" }
            } else if let atRange = name.range(of: "USBXHCI@0") {
                _ = atRange
                if let at = name.range(of: "@0") {
                    if let first = name[at.upperBound...].first, let n = Int(String(first)) { port = "Port-USB-C@\(n + 1)" }
                }
            }
        }
        guard let port else { return }
        var mapping = portMaps[port] ?? PortMapping()

        if let productName {
            insert(Accessory(name: productName, speed: accessorySpeed(node)), into: &mapping.displays)
        }
        if let uid = metadata?["UID"] as? NSNumber {
            mapping.uids.insert(String(uid.uint64Value)) // stored as signed Int64; ioreg shows it unsigned
        }
        portMaps[port] = mapping
    }

    /// One accessory per product name. Several registry entries describe the same device (device,
    /// interface, …) and only some carry a speed; keep the first speed seen so the result doesn't
    /// depend on set ordering and a device is never counted twice.
    private static func insert(_ accessory: Accessory, into set: inout Set<Accessory>) {
        if let existing = set.first(where: { $0.name == accessory.name }) {
            guard existing.speed == nil, accessory.speed != nil else { return }
            set.remove(existing)
        }
        set.insert(accessory)
    }

    private static func accessorySpeed(_ node: IORegistryNode) -> String? {
        if let s = node.int("Device Speed") {
            switch s {
            case 0, 1: return "12 Mbps"
            case 2: return "480 Mbps"
            case 3: return "5 Gbps"
            case 4: return "10 Gbps"
            case 5: return "20 Gbps"
            default: break
            }
        }
        // Only device-level entries carry "Device Speed". Interface-level entries ("USBSpeed") share the
        // same product name, and counting their speed would double-count one physical device.
        return nil
    }

    // MARK: - USB device details (was RegistryHelpers.parseUSBDeviceDetails)

    private static func collectUSBDetails(_ node: IORegistryNode, _ result: inout [String: PeripheralDetails]) {
        // kUSBProductString is the real device string and carries the full USB descriptor details.
        guard let name = node.string("kUSBProductString") ?? node.string("USB Product Name") ?? node.string("Product Name") ?? node.string("ProductName"),
              !name.isEmpty, result[name] == nil else { return }

        let vendorId = node.int("idVendor").map { String(format: "0x%04X", $0) }
        let productId = node.int("idProduct").map { String(format: "0x%04X", $0) }
        let usbVer = node.int("bcdUSB").map { RegistryHelpers.bcdToVersionString($0) }
        let devVer = node.int("bcdDevice").map { RegistryHelpers.bcdToVersionString($0) }
        let speed = node.int("Device Speed").map { RegistryHelpers.usbSpeedString($0) }
        let power = node.int("nCurrentRequired").map { "\($0) mA" }
        let pd = PeripheralDetails(
            vendor: node.string("kUSBVendorString") ?? node.string("USB Vendor Name") ?? node.string("Vendor Name"),
            uid: nil, vendorId: vendorId, productId: productId,
            serialNumber: node.string("kUSBSerialNumberString"),
            speed: speed, usbVersion: usbVer, deviceVersion: devVer,
            powerAvailable: nil, powerUsed: power, locationId: nil,
            tbDeviceId: nil, tbVendorId: nil, tbRevision: nil, tbFirmware: nil, tbMode: nil,
            tbRouteString: nil, tbDomainUUID: nil, tbDownstreamPorts: nil, bsdName: nil
        )
        if pd.hasAnyDetail { result[name] = pd }
    }

    // MARK: - BSD names ↔ devices (was RegistryHelpers.parseBSDMappings)

    private static let ignoredAncestors: Set<String> = ["AppleDiskImagesController", "IOHDIXController", "IOUserEthernetResource", "AppleANS3CGv2Controller"]
    private static let derivedVolumeAncestors: Set<String> = ["AppleAPFSContainerScheme", "AppleAPFSMedia", "IOGUIDPartitionScheme"]

    private static func collectBSD(_ node: IORegistryNode, _ path: [String], _ result: inout RegistryHelpers.BSDMappingResult) {
        guard let bsdName = node.string("BSD Name") else { return }
        // Old text parser matched ancestor names as printed by ioreg: "<name>@<location>" (class names for the
        // ignore/derived lists are matched on the entry *name*, which is the same text before any "@").
        let baseNames = path.map { $0.split(separator: "@", maxSplits: 1).first.map(String.init) ?? $0 }
        guard !baseNames.contains(where: { ignoredAncestors.contains($0) }) else { return }

        let isDisk = bsdName.hasPrefix("disk")
        let isPhysical = RegistryHelpers.isPhysicalDisk(bsdName)
        if isDisk && !isPhysical { return }
        if isPhysical, baseNames.contains(where: { derivedVolumeAncestors.contains($0) }) { return }

        let ordered = path.reversed().filter { RegistryHelpers.isRealProductName($0) }
        if !ordered.isEmpty { result.candidatesByBSDName[bsdName, default: []].append(contentsOf: ordered) }
        if isPhysical { result.allPhysicalDisks.insert(bsdName) }
    }

    // MARK: - Display Stream Compression + display details

    private static func displayProductName(_ node: IORegistryNode) -> String? {
        node.string("DisplayProductName") ?? node.string("ProductName")
    }

    private static func collectDSC(_ node: IORegistryNode, _ path: [String], _ result: inout Set<String>) {
        guard let flag = node["DisplayStreamCompression"] else { return }
        let active: Bool
        switch flag {
        case let b as Bool: active = b
        case let n as NSNumber: active = n.intValue != 0
        case let d as Data: active = d.contains { $0 != 0 }
        default: active = false
        }
        guard active, let name = displayProductName(node) ?? ancestorProductName(node) else { return }
        result.insert(name)
    }

    private static func ancestorProductName(_ node: IORegistryNode) -> String? {
        var current = IOKitRegistry.parent(of: node)
        var depth = 0
        while let c = current, depth < 8 {
            defer { IOObjectRelease(c.entry) }
            if let name = displayProductName(c) { return name }
            current = IOKitRegistry.parent(of: c)
            depth += 1
        }
        return nil
    }

    private static func emptyDetails() -> DisplayDetails {
        DisplayDetails(displayUID: nil, vendor: nil, model: nil, connectionType: nil, bitDepth: nil, nativeResolution: nil, isScaled: nil, edidSerial: nil, edidMfgDate: nil, dscVersion: nil, dscMode: nil, dscRatio: nil, maxResolution: nil, hdrSupport: nil, panelType: nil)
    }

    private static func collectDisplayDetails(_ node: IORegistryNode, _ currentName: inout String, _ current: inout DisplayDetails, _ all: inout [String: DisplayDetails]) {
        if let name = displayProductName(node) {
            if !currentName.isEmpty { all[currentName] = current }
            currentName = name
            current = emptyDetails()
        }
        guard !currentName.isEmpty else { return }

        if let location = node.string("IODisplayLocation") { current.connectionType = location }
        if let edid = node.data("IODisplayEDID") ?? node.data("EDID") {
            // EDID 1.4 byte 20, bits 6–4: colour bit depth of a digital input.
            if edid.count > 20, edid[20] & 0x80 != 0 {
                switch (edid[20] >> 4) & 0x7 {
                case 1: current.bitDepth = "6-bit"
                case 2: current.bitDepth = "8-bit"
                case 3: current.bitDepth = "10-bit"
                case 4: current.bitDepth = "12-bit"
                case 5: current.bitDepth = "14-bit"
                case 6: current.bitDepth = "16-bit"
                default: break
                }
            }
        }
        if let v = node["DisplayStreamCompressionVersion"] { current.dscVersion = "\(v)" }
        if let m = node["DisplayStreamCompressionMode"] { current.dscMode = "\(m)" }
    }
}
