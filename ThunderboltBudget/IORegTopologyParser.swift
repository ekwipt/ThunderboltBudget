import Foundation

struct Accessory: Hashable {
    let name: String
    let speed: String?
}

struct PortMapping {
    var uids: Set<String> = []
    var displays: Set<Accessory> = []
}

class IORegTopologyParser {
    
    /// Returns a dictionary mapping a Hub's Decimal UID to an array of Accessory properties attached to the same physical port
    static func getDisplayMappings() -> [String: [Accessory]] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l"]
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            // Raw IORegistry output often contains binary firmware/EDID blobs that are invalid UTF-8.
            // We MUST use the lossy decoder here, otherwise the entire string conversion silently returns nil!
            let output = String(decoding: data, as: UTF8.self)
            return parseOutput(output)
        } catch {
            print("Failed to run ioreg")
        }
        return [:]
    }
    
    private static func parseOutput(_ output: String) -> [String: [Accessory]] {
        var portMaps: [String: PortMapping] = [:]
        var currPath: [(indent: Int, name: String)] = []
        
        let lines = output.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let leading = line.prefix(while: { " |+-".contains($0) })
            let indent = leading.count
            
            let cleanName = getCleanName(line)
            
            while let last = currPath.last, last.indent >= indent {
                currPath.removeLast()
            }
            
            currPath.append((indent: indent, name: cleanName))
            
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.contains("\"ProductName\" =") || text.contains("\"Product Name\" =") || text.contains("\"USB Product Name\" =") || text.contains("\"Metadata\" =") {
                
                // Find nearest physical Port-USB-C in our tracked path hierarchy
                // Note: Apple Silicon tunnels USB traffic via built-in XHCI controllers (usb-drdX), independent of Port-USB-C!
                var port: String? = nil
                for p in currPath {
                    if p.name.contains("Port-USB-C") {
                        port = p.name
                    } else if p.name.contains("usb-drd") {
                        if let drdRange = p.name.range(of: "usb-drd") {
                            let substring = p.name[drdRange.upperBound...]
                            let digitStr = substring.prefix(while: { $0.isNumber })
                            if let drdNum = Int(digitStr) {
                                // Maps drd0 -> Port-USB-C@1, drd1 -> Port-USB-C@2
                                port = "Port-USB-C@\(drdNum + 1)"
                            }
                        }
                    } else if p.name.contains("USBXHCI@0") {
                         if let atRange = p.name.range(of: "@0") {
                             let substring = p.name[atRange.upperBound...]
                             if let firstChar = substring.first, let drdNum = Int(String(firstChar)) {
                                 port = "Port-USB-C@\(drdNum + 1)"
                             }
                         }
                    }
                }
                
                if let port = port {
                    var mapping = portMaps[port] ?? PortMapping()
                    
                    if text.contains("\"ProductName\" =") || text.contains("\"Product Name\" =") || text.contains("\"USB Product Name\" =") {
                        let parts = text.components(separatedBy: "=")
                        if parts.count >= 2 {
                            let val = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            
                            var speedStr: String? = nil
                            // Scan ahead up to 30 lines for Device Speed parameters nested under this accessory
                            let maxScan = min(index + 30, lines.count)
                            for j in (index + 1)..<maxScan {
                                let lookahead = lines[j]
                                if lookahead.contains("\"Device Speed\" =") {
                                    if lookahead.contains("= 0") || lookahead.contains("= 1") { speedStr = "12 Mbps" }
                                    else if lookahead.contains("= 2") { speedStr = "480 Mbps" }
                                    else if lookahead.contains("= 3") { speedStr = "5 Gbps" }
                                    else if lookahead.contains("= 4") { speedStr = "10 Gbps" }
                                    else if lookahead.contains("= 5") { speedStr = "20 Gbps" }
                                    break
                                } else if lookahead.contains("\"USBSpeed\" =") && speedStr == nil {
                                    if lookahead.contains("= 3") { speedStr = "480 Mbps" }
                                    else if lookahead.contains("= 4") { speedStr = "5 Gbps" }
                                    else if lookahead.contains("= 5") { speedStr = "10 Gbps" }
                                }
                            }
                            
                            mapping.displays.insert(Accessory(name: val, speed: speedStr))
                        }
                    } 
                    else if text.contains("\"Metadata\" =") {
                        // Extract UID
                        // Format: "Metadata" = {"ROM Version"=0,"UID"=9261552895846297600,...}
                        if let range = text.range(of: "\"UID\"=") {
                            let substring = text[range.upperBound...]
                            let uidStr = substring.prefix(while: { $0.isNumber })
                            if !uidStr.isEmpty {
                                mapping.uids.insert(String(uidStr))
                            }
                        }
                    }
                    portMaps[port] = mapping
                }
            }
        }
        
        var uidToDisplays: [String: [Accessory]] = [:]
        for mapping in portMaps.values {
            for uid in mapping.uids {
                uidToDisplays[uid] = Array(mapping.displays)
            }
        }
        return uidToDisplays
    }

    private static func getCleanName(_ line: String) -> String {
        let parts = line.components(separatedBy: "+-o ")
        guard parts.count > 1 else { return "" }
        let subParts = parts.last!.components(separatedBy: "  <")
        return subParts.first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Returns the product names of displays that have negotiated Display Stream Compression.
    static func getDSCActiveDisplayNames() -> Set<String> {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l", "-c", "IODisplayConnect"]
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return parseDSCDisplays(output)
        } catch {
            print("ThunderboltBudget: Failed to run ioreg for DSC detection")
        }
        return []
    }

    private static func parseDSCDisplays(_ output: String) -> Set<String> {
        var dscNames: Set<String> = []
        let lines = output.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("\"DisplayStreamCompression\"") else { continue }

            // Accept Yes, 1, or a non-zero hex blob like <01>
            let isActive = trimmed.contains("= Yes") || trimmed.contains("= 1") || trimmed.contains("= <01>")
            guard isActive else { continue }

            // Scan backward up to 80 lines to find the owning display's ProductName
            let scanStart = max(0, index - 80)
            for j in stride(from: index - 1, through: scanStart, by: -1) {
                let candidate = lines[j].trimmingCharacters(in: .whitespaces)
                if candidate.contains("\"DisplayProductName\" =") || candidate.contains("\"ProductName\" =") {
                    let parts = candidate.components(separatedBy: "=")
                    if parts.count >= 2 {
                        let val = parts[1]
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if !val.isEmpty {
                            dscNames.insert(val)
                        }
                    }
                    break
                }
            }
        }
        return dscNames
    }

    /// Extracts detailed information about displays from IORegistry, including connection type, EDID info, and DSC parameters
    static func getDisplayDetails() -> [String: DisplayDetails] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l", "-c", "IODisplayConnect"]
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return parseDisplayDetails(output)
        } catch {
            print("ThunderboltBudget: Failed to run ioreg for display details")
        }
        return [:]
    }

    private static func parseDisplayDetails(_ output: String) -> [String: DisplayDetails] {
        var details: [String: DisplayDetails] = [:]
        let lines = output.components(separatedBy: .newlines)

        var currentDisplayName = ""
        var currentDetails = DisplayDetails(displayUID: nil, vendor: nil, model: nil, connectionType: nil, bitDepth: nil, nativeResolution: nil, isScaled: nil, edidSerial: nil, edidMfgDate: nil, dscVersion: nil, dscMode: nil, dscRatio: nil, maxResolution: nil, hdrSupport: nil, panelType: nil)

        for (_, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track current display
            if trimmed.contains("\"DisplayProductName\" =") || trimmed.contains("\"ProductName\" =") {
                if !currentDisplayName.isEmpty {
                    details[currentDisplayName] = currentDetails
                }
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    currentDisplayName = parts[1]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                currentDetails = DisplayDetails(displayUID: nil, vendor: nil, model: nil, connectionType: nil, bitDepth: nil, nativeResolution: nil, isScaled: nil, edidSerial: nil, edidMfgDate: nil, dscVersion: nil, dscMode: nil, dscRatio: nil, maxResolution: nil, hdrSupport: nil, panelType: nil)
            }

            // Extract connection type
            if trimmed.contains("\"IODisplayLocation\" =") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let connType = parts[1]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    currentDetails = DisplayDetails(displayUID: currentDetails.displayUID, vendor: currentDetails.vendor, model: currentDetails.model, connectionType: connType, bitDepth: currentDetails.bitDepth, nativeResolution: currentDetails.nativeResolution, isScaled: currentDetails.isScaled, edidSerial: currentDetails.edidSerial, edidMfgDate: currentDetails.edidMfgDate, dscVersion: currentDetails.dscVersion, dscMode: currentDetails.dscMode, dscRatio: currentDetails.dscRatio, maxResolution: currentDetails.maxResolution, hdrSupport: currentDetails.hdrSupport, panelType: currentDetails.panelType)
                }
            }

            // Extract bit depth
            if trimmed.contains("\"IODisplayEDID\" =") || trimmed.contains("\"DisplayBitDepth\" =") {
                // Try to infer bit depth (10-bit would contain "10" or "HDR", 8-bit is default)
                if trimmed.contains("10") {
                    currentDetails = DisplayDetails(displayUID: currentDetails.displayUID, vendor: currentDetails.vendor, model: currentDetails.model, connectionType: currentDetails.connectionType, bitDepth: "10-bit", nativeResolution: currentDetails.nativeResolution, isScaled: currentDetails.isScaled, edidSerial: currentDetails.edidSerial, edidMfgDate: currentDetails.edidMfgDate, dscVersion: currentDetails.dscVersion, dscMode: currentDetails.dscMode, dscRatio: currentDetails.dscRatio, maxResolution: currentDetails.maxResolution, hdrSupport: currentDetails.hdrSupport, panelType: currentDetails.panelType)
                } else if currentDetails.bitDepth == nil {
                    currentDetails = DisplayDetails(displayUID: currentDetails.displayUID, vendor: currentDetails.vendor, model: currentDetails.model, connectionType: currentDetails.connectionType, bitDepth: "8-bit", nativeResolution: currentDetails.nativeResolution, isScaled: currentDetails.isScaled, edidSerial: currentDetails.edidSerial, edidMfgDate: currentDetails.edidMfgDate, dscVersion: currentDetails.dscVersion, dscMode: currentDetails.dscMode, dscRatio: currentDetails.dscRatio, maxResolution: currentDetails.maxResolution, hdrSupport: currentDetails.hdrSupport, panelType: currentDetails.panelType)
                }
            }

            // Extract DSC info
            if trimmed.contains("\"DisplayStreamCompressionVersion\" =") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let version = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    currentDetails = DisplayDetails(displayUID: currentDetails.displayUID, vendor: currentDetails.vendor, model: currentDetails.model, connectionType: currentDetails.connectionType, bitDepth: currentDetails.bitDepth, nativeResolution: currentDetails.nativeResolution, isScaled: currentDetails.isScaled, edidSerial: currentDetails.edidSerial, edidMfgDate: currentDetails.edidMfgDate, dscVersion: version, dscMode: currentDetails.dscMode, dscRatio: currentDetails.dscRatio, maxResolution: currentDetails.maxResolution, hdrSupport: currentDetails.hdrSupport, panelType: currentDetails.panelType)
                }
            }

            if trimmed.contains("\"DisplayStreamCompressionMode\" =") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let mode = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    currentDetails = DisplayDetails(displayUID: currentDetails.displayUID, vendor: currentDetails.vendor, model: currentDetails.model, connectionType: currentDetails.connectionType, bitDepth: currentDetails.bitDepth, nativeResolution: currentDetails.nativeResolution, isScaled: currentDetails.isScaled, edidSerial: currentDetails.edidSerial, edidMfgDate: currentDetails.edidMfgDate, dscVersion: currentDetails.dscVersion, dscMode: mode, dscRatio: currentDetails.dscRatio, maxResolution: currentDetails.maxResolution, hdrSupport: currentDetails.hdrSupport, panelType: currentDetails.panelType)
                }
            }
        }

        if !currentDisplayName.isEmpty {
            details[currentDisplayName] = currentDetails
        }

        return details
    }

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

    /// Maps BSD disk/network identifiers to candidate device names by walking the full IORegistry tree.
    static func getBSDDeviceMappings() -> BSDMappingResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseBSDMappings(String(decoding: data, as: UTF8.self))
        } catch {
            return BSDMappingResult()
        }
    }

    private static func isPhysicalDisk(_ bsdName: String) -> Bool {
        guard bsdName.hasPrefix("disk") else { return false }
        let rest = bsdName.dropFirst(4)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }

    // Ancestor names that are internal IOKit/driver plumbing, not a real product name — matching
    // against these causes false positives, since the same generic label (e.g. "USB3.0 Hub") is
    // reused across many unrelated physical devices system-wide.
    private static func isRealProductName(_ name: String) -> Bool {
        if name.hasPrefix("Apple") || name.hasPrefix("IO") { return false }
        let generic: Set<String> = ["USB2.0 Hub", "USB2.1 Hub", "USB3.0 Hub", "USB3.1 Hub", "Hub Feature Controller", "Media"]
        if generic.contains(name) { return false }
        return true
    }

    private static func parseBSDMappings(_ output: String) -> BSDMappingResult {
        var result = BSDMappingResult()
        var currPath: [(indent: Int, name: String)] = []

        // Virtual/internal devices we never want to attribute traffic to: disk images,
        // the internal boot SSD, and virtual network adapters (vmenetN, used by VMs).
        let ignoredAncestors: Set<String> = ["AppleDiskImagesController", "IOHDIXController", "IOUserEthernetResource", "AppleANS3CGv2Controller"]
        // A BSD name found beneath one of these is a derived/synthesized volume (an APFS container
        // built on top of a physical disk's partition), not a physical device iostat -I reports on.
        let derivedVolumeAncestors: Set<String> = ["AppleAPFSContainerScheme", "AppleAPFSMedia", "IOGUIDPartitionScheme"]

        for line in output.components(separatedBy: .newlines) {
            let leading = line.prefix(while: { " |+-".contains($0) })
            let indent = leading.count
            let cleanName = getCleanName(line)

            if !cleanName.isEmpty {
                while let last = currPath.last, last.indent >= indent { currPath.removeLast() }
                currPath.append((indent: indent, name: cleanName))
                continue
            }

            guard !currPath.isEmpty else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("\"BSD Name\" ="), let bsdName = extractValue(t) else { continue }
            guard !currPath.contains(where: { ignoredAncestors.contains($0.name) }) else { continue }

            let isDiskPartition = bsdName.hasPrefix("disk") && !isPhysicalDisk(bsdName)
            if isDiskPartition { continue } // only track physical disks, not volumes/slices
            if isPhysicalDisk(bsdName), currPath.contains(where: { derivedVolumeAncestors.contains($0.name) }) {
                continue // synthesized APFS container disk, not a real iostat-tracked physical device
            }

            // currPath is outermost-first; reversed() gives innermost (most specific) first.
            let orderedCandidates = currPath.reversed().map { $0.name }.filter { isRealProductName($0) }
            if !orderedCandidates.isEmpty {
                result.candidatesByBSDName[bsdName, default: []].append(contentsOf: orderedCandidates)
            }
            if isPhysicalDisk(bsdName) {
                result.allPhysicalDisks.insert(bsdName)
            }
        }
        return result
    }

    /// Returns a map of USB product name → PeripheralDetails populated from IORegistry.
    /// On Apple Silicon, SPUSBDataType is empty; this is the only way to get USB device detail.
    static func getUSBDeviceDetails() -> [String: PeripheralDetails] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        // Thunderbolt-tunneled USB devices don't always register under IOUSBHostDevice,
        // so scan the full tree (same approach as getDisplayMappings) instead of filtering by class.
        process.arguments = ["-l"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return parseUSBDeviceDetails(output)
        } catch {
            return [:]
        }
    }

    private static func parseUSBDeviceDetails(_ output: String) -> [String: PeripheralDetails] {
        var result: [String: PeripheralDetails] = [:]
        var props: [String: String] = [:]

        func save() {
            guard let name = props["name"], !name.isEmpty, result[name] == nil else { return }
            let vendorId = props["idVendor"].flatMap { Int($0) }.map { String(format: "0x%04X", $0) }
            let productId = props["idProduct"].flatMap { Int($0) }.map { String(format: "0x%04X", $0) }
            let usbVer   = props["bcdUSB"].flatMap { Int($0) }.map { bcdToVersionString($0) }
            let devVer   = props["bcdDevice"].flatMap { Int($0) }.map { bcdToVersionString($0) }
            let speed    = props["deviceSpeed"].flatMap { Int($0) }.map { usbSpeedString($0) }
            let power    = props["power"].flatMap { Int($0) }.map { "\($0) mA" }
            let pd = PeripheralDetails(
                vendor: props["vendor"], uid: nil,
                vendorId: vendorId, productId: productId,
                serialNumber: props["serial"],
                speed: speed, usbVersion: usbVer, deviceVersion: devVer,
                powerAvailable: nil, powerUsed: power, locationId: nil,
                tbDeviceId: nil, tbVendorId: nil, tbRevision: nil,
                tbFirmware: nil, tbMode: nil, tbRouteString: nil,
                tbDomainUUID: nil, tbDownstreamPorts: nil,
                bsdName: nil
            )
            if pd.hasAnyDetail { result[name] = pd }
        }

        for line in output.components(separatedBy: .newlines) {
            if line.contains("+-o ") {
                save()
                props = [:]
                continue
            }
            // ioreg's tree-drawing prefix ("| | +-o ...") isn't stripped by whitespace trimming,
            // so match key text anywhere in the line rather than anchoring to its start.
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("\"USB Product Name\" =") || t.contains("\"Product Name\" =") || t.contains("\"ProductName\" =") || t.contains("\"kUSBProductString\" =") {
                if props["name"] == nil { props["name"] = extractValue(t) }
            } else if t.contains("\"kUSBVendorString\" =") || t.contains("\"USB Vendor Name\" =") || t.contains("\"Vendor Name\" =") {
                if props["vendor"] == nil { props["vendor"] = extractValue(t) }
            } else if t.contains("\"kUSBSerialNumberString\" =") {
                props["serial"] = extractValue(t)
            } else if t.contains("\"idVendor\" =") {
                props["idVendor"] = extractNumeric(t)
            } else if t.contains("\"idProduct\" =") {
                props["idProduct"] = extractNumeric(t)
            } else if t.contains("\"bcdUSB\" =") {
                props["bcdUSB"] = extractNumeric(t)
            } else if t.contains("\"bcdDevice\" =") {
                props["bcdDevice"] = extractNumeric(t)
            } else if t.contains("\"Device Speed\" =") {
                if props["deviceSpeed"] == nil { props["deviceSpeed"] = extractNumeric(t) }
            } else if t.contains("\"nCurrentRequired\" =") {
                props["power"] = extractNumeric(t)
            }
        }
        save()
        return result
    }

    private static func extractValue(_ line: String) -> String? {
        guard let r = line.range(of: " = ") else { return nil }
        let raw = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw.isEmpty ? nil : raw
    }

    private static func extractNumeric(_ line: String) -> String? {
        guard let r = line.range(of: " = ") else { return nil }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func bcdToVersionString(_ value: Int) -> String {
        let major = (value >> 8) & 0xFF
        let minor = (value & 0xFF) >> 4
        return "\(major).\(minor)"
    }

    private static func usbSpeedString(_ speed: Int) -> String {
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
