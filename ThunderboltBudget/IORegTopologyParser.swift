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
}
