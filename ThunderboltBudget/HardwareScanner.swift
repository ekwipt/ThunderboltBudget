import Foundation

struct HardwareScanner {
    
    // Scans exactly the same data trees, but as JSON, and decodes them into robust generic tree nodes
    func scanForDevices() -> [DeviceNode] {
        let rawData = fetchRegistryDump()
        return parseJSONOutput(rawData)
    }

    // Fetches native JSON output from the hardware profiler
    func fetchRegistryDump() -> Data {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPThunderboltDataType", "SPUSBDataType", "SPDisplaysDataType"]
        
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        } catch {
            return Data()
        }
    }

    private func parseJSONOutput(_ data: Data) -> [DeviceNode] {
        guard let root = try? JSONDecoder().decode(SPProfileRoot.self, from: data) else {
            return []
        }

        // 1. Map physical DisplayPort streams and display details using our custom IOKit scanner
        let displayMappings = IORegTopologyParser.getDisplayMappings()
        let dscDisplayNames = IORegTopologyParser.getDSCActiveDisplayNames()
        let displayDetailsMap = IORegTopologyParser.getDisplayDetails()
        let usbDetails = IORegTopologyParser.getUSBDeviceDetails()
        let bsdMappings = IORegTopologyParser.getBSDDeviceMappings()

        // 2. Extract displays
        var allDisplays: [DeviceNode] = []
        if let dispNodes = root.SPDisplaysDataType {
            for gpu in dispNodes {
                if let ndrvs = gpu.spdisplays_ndrvs {
                    allDisplays.append(contentsOf: mapNodes(ndrvs, defaultIcon: "display", dscDisplayNames: dscDisplayNames, displayDetailsMap: displayDetailsMap) ?? [])
                }
            }
        }
        
        // 3. Map Thunderbolt and USB trees, and inject accessories into matched hubs
        var finalNodes: [DeviceNode] = []
        
        // Extract USB root tree
        var usbNodes: [DeviceNode] = []
        if let usbRaw = root.SPUSBDataType, let mapped = mapNodes(usbRaw, defaultIcon: "cable.connector") {
            usbNodes = mapped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        
        // Snapshot before injection so the Displays section always lists every display,
        // even those that get placed under a Thunderbolt port.
        let allDisplaysSnapshot = allDisplays

        if let tbNodes = root.SPThunderboltDataType,
           let mapped = mapNodes(tbNodes, defaultIcon: "bolt.fill") {
            let sortedMapped = mapped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let injected = injectAccessories(into: sortedMapped, availableDisplays: &allDisplays, usbNodes: &usbNodes, mappings: displayMappings)
            
            // Post-process the injected nodes to add root bandwidth ratios
            var customizedRootPorts: [DeviceNode] = []
            for port in injected {
                var maxCap = 40.0
                if let oldLabel = port.bandwidthLabel {
                    let clean = oldLabel.replacingOccurrences(of: " Gb/s", with: "").replacingOccurrences(of: " Gbps", with: "")
                    maxCap = Double(clean) ?? 40.0
                }
                
                // Sum all endpoints under this physical port
                let totalGbps = sumBandwidth(of: [port])
                let ratio = min(totalGbps / maxCap, 1.0)
                let newLabel = String(format: "%.1f / %.0f Gbps", totalGbps, maxCap)
                
                let newNode = DeviceNode(id: port.id, name: port.name, iconName: port.iconName, bandwidthLabel: newLabel, uid: port.uid, children: port.children, bandwidthRatio: ratio, peripheralDetails: port.peripheralDetails)
                customizedRootPorts.append(newNode)
            }
            
            finalNodes.append(DeviceNode(name: "Thunderbolt Bus", iconName: "bolt.circle.fill", children: customizedRootPorts))
        }
        
        if !usbNodes.isEmpty {
            finalNodes.append(DeviceNode(name: "USB Bus", iconName: "command.circle.fill", children: usbNodes))
        }
        
        // 4. All displays go into the root Displays folder (external displays may also appear under their TB port)
        if !allDisplaysSnapshot.isEmpty {
            finalNodes.append(DeviceNode(name: "Displays", iconName: "rectangle.stack.fill", children: allDisplaysSnapshot))
        }
        
        let enriched = enrichWithUSBDetails(pruneEmptyHubs(from: finalNodes), usbDetails: usbDetails)
        return attachLiveBSDNames(to: enriched, mappings: bsdMappings)
    }

    // Correlates physical devices with the BSD identifiers iostat/netstat report throughput for,
    // so LiveAnalytics can be matched back to a specific device in the tree.
    private func attachLiveBSDNames(to nodes: [DeviceNode], mappings: IORegTopologyParser.BSDMappingResult) -> [DeviceNode] {
        var usedBSDNames = Set<String>()

        func withBSDName(_ pd: PeripheralDetails, _ bsdName: String) -> PeripheralDetails {
            PeripheralDetails(
                vendor: pd.vendor, uid: pd.uid, vendorId: pd.vendorId, productId: pd.productId,
                serialNumber: pd.serialNumber, speed: pd.speed, usbVersion: pd.usbVersion, deviceVersion: pd.deviceVersion,
                powerAvailable: pd.powerAvailable, powerUsed: pd.powerUsed, locationId: pd.locationId,
                tbDeviceId: pd.tbDeviceId, tbVendorId: pd.tbVendorId, tbRevision: pd.tbRevision, tbFirmware: pd.tbFirmware,
                tbMode: pd.tbMode, tbRouteString: pd.tbRouteString, tbDomainUUID: pd.tbDomainUUID, tbDownstreamPorts: pd.tbDownstreamPorts,
                bsdName: bsdName
            )
        }

        // Assigns bsdName to the first node (depth-first) whose name fuzzy-matches candidateName
        // and doesn't already have a bsdName. Stops after one match so a bsdName is never attached twice.
        func tryAssign(_ bsdName: String, matching candidateName: String, in nodeList: [DeviceNode]) -> (nodes: [DeviceNode], assigned: Bool) {
            var assigned = false
            var newNodes: [DeviceNode] = []
            for node in nodeList {
                var n = node
                if !assigned, let children = n.children {
                    let (newChildren, childAssigned) = tryAssign(bsdName, matching: candidateName, in: children)
                    n.children = newChildren
                    assigned = childAssigned
                }
                if !assigned, let pd = n.peripheralDetails, pd.bsdName == nil,
                   n.name.localizedCaseInsensitiveContains(candidateName) || candidateName.localizedCaseInsensitiveContains(n.name) {
                    n.peripheralDetails = withBSDName(pd, bsdName)
                    assigned = true
                }
                newNodes.append(n)
            }
            return (newNodes, assigned)
        }

        // Pass 1: match by device name, preferring the most specific (innermost) ancestor name
        // first — e.g. try "USB 10/100/1000 LAN" (the actual accessory) before "USB5906 Smart Hub"
        // (the internal hub chip it happens to be plugged into, which several devices might share).
        var result = nodes
        for (bsdName, candidates) in mappings.candidatesByBSDName {
            guard !usedBSDNames.contains(bsdName) else { continue }
            for candidateName in candidates {
                let (updated, assigned) = tryAssign(bsdName, matching: candidateName, in: result)
                if assigned {
                    result = updated
                    usedBSDNames.insert(bsdName)
                    break
                }
            }
        }

        // Pass 2: elimination fallback. Thunderbolt-tunneled NVMe enclosures (e.g. OWC Express 1M2)
        // register in IORegistry under their raw internal drive's PCIe chain, not their enclosure's
        // product name, so name matching can't find them. If exactly one physical disk and exactly
        // one storage-looking device are both still unmatched, they're almost certainly each other.
        let leftoverDisks = mappings.allPhysicalDisks.subtracting(usedBSDNames)
        if leftoverDisks.count == 1, let onlyDisk = leftoverDisks.first {
            let storageKeywords = ["ssd", "nvme", "express", "passport", "drive", "disk", "storage", "raid"]
            var storageLeafNames: [String] = []
            func findStorageLeaves(_ nodeList: [DeviceNode]) {
                for node in nodeList {
                    if let children = node.children, !children.isEmpty {
                        findStorageLeaves(children)
                    } else if node.peripheralDetails?.bsdName == nil,
                              storageKeywords.contains(where: { node.name.lowercased().contains($0) }) {
                        storageLeafNames.append(node.name)
                    }
                }
            }
            findStorageLeaves(result)
            if storageLeafNames.count == 1 {
                let targetName = storageLeafNames[0]
                func assign(_ nodeList: [DeviceNode]) -> [DeviceNode] {
                    nodeList.map { node in
                        var n = node
                        if let children = n.children { n.children = assign(children) }
                        if n.name == targetName, let pd = n.peripheralDetails, pd.bsdName == nil {
                            n.peripheralDetails = withBSDName(pd, onlyDisk)
                        }
                        return n
                    }
                }
                result = assign(result)
            }
        }

        return result
    }

    // Walk the full node tree and attach USB details from IORegistry to any node that lacks peripheral details
    private func enrichWithUSBDetails(_ nodes: [DeviceNode], usbDetails: [String: PeripheralDetails]) -> [DeviceNode] {
        nodes.map { node in
            var n = node
            if let children = n.children {
                n.children = enrichWithUSBDetails(children, usbDetails: usbDetails)
            }
            if n.peripheralDetails == nil && n.displayDetails == nil {
                for (productName, details) in usbDetails {
                    if n.name.localizedCaseInsensitiveContains(productName) ||
                       productName.localizedCaseInsensitiveContains(n.name) {
                        n.peripheralDetails = details
                        break
                    }
                }
            }
            return n
        }
    }

    // Prune unused internal hubs (e.g. empty USB hubs that monitor structural boards expose)
    private func pruneEmptyHubs(from nodes: [DeviceNode]) -> [DeviceNode] {
        var pruned: [DeviceNode] = []
        for node in nodes {
            var mutableNode = node
            if let children = mutableNode.children {
                let remaining = pruneEmptyHubs(from: children)
                mutableNode.children = remaining.isEmpty ? nil : remaining
            }
            
            let lower = mutableNode.name.lowercased()
            let isGenericHub = lower == "usb2.0 hub" || lower == "usb2.1 hub" || lower == "usb3.0 hub" || lower == "usb3.1 hub" || lower == "hub feature controller"
            
            // Do not prune primary Thunderbolt Hubs even if empty
            let isMainTBHub = lower.contains("owc") || lower.contains("sonnet") || lower.contains("echo") || lower == "thunderbolt hub"
            
            if isGenericHub && !isMainTBHub && mutableNode.children == nil {
                continue
            }
            
            pruned.append(mutableNode)
        }
        return pruned
    }

    private func injectAccessories(into nodes: [DeviceNode], availableDisplays: inout [DeviceNode], usbNodes: inout [DeviceNode], mappings: [String: [Accessory]]) -> [DeviceNode] {
        var newNodes: [DeviceNode] = []
        for node in nodes {
            var mutableNode = node
            
            // Recurse first
            if let children = mutableNode.children {
                mutableNode.children = injectAccessories(into: children, availableDisplays: &availableDisplays, usbNodes: &usbNodes, mappings: mappings)
            }
            
            // Do we match a Hub UID?
            if let uidHex = mutableNode.uid, 
               let decStr = hexToDec(uidHex), 
               let mappedAccessories = mappings[decStr] {
                
                var matchedAccessories: [DeviceNode] = []
                
                // Pluck Displays
                for accessory in mappedAccessories {
                    if let idx = availableDisplays.firstIndex(where: { $0.name.localizedCaseInsensitiveContains(accessory.name) }) {
                        let extracted = availableDisplays.remove(at: idx)
                        let newLabel = extracted.bandwidthLabel ?? accessory.speed
                        matchedAccessories.append(DeviceNode(id: extracted.id, name: extracted.name, iconName: extracted.iconName, bandwidthLabel: newLabel, uid: extracted.uid, children: extracted.children, dscActive: extracted.dscActive, displayDetails: extracted.displayDetails, rawBandwidth: extracted.rawBandwidth))
                    }
                }
                
                // Pluck deeply nested USB accessories automatically
                usbNodes = extractMatching(from: usbNodes, accessories: mappedAccessories, extracted: &matchedAccessories)
                
                // Check if macOS SPUSBDataType completely failed to report the device (common bug)
                // If it missed it, but IORegistry knows it's plugged into this exact port, we synthesize it!
                for accessory in mappedAccessories {
                    let wasMatched = matchedAccessories.contains { $0.name.localizedCaseInsensitiveContains(accessory.name) }
                    
                    if !wasMatched {
                        let lower = accessory.name.lowercased()
                        // Ignore the hidden internal structural hubs that don't mean anything to users
                        if lower.contains("thunderbolt") { continue }
                        if lower == "usb2.0 hub" || lower == "usb2.1 hub" || lower == "usb3.0 hub" || lower == "usb3.1 hub" || lower == "hub feature controller" { continue }
                        
                        let syntheticIcon = accessory.name.localizedCaseInsensitiveContains("hub") ? "point.3.connected.trianglepath.dotted" : "cable.connector"
                        matchedAccessories.append(DeviceNode(name: accessory.name, iconName: syntheticIcon, bandwidthLabel: accessory.speed))
                    }
                }
                
                if !matchedAccessories.isEmpty {
                    var newChildren = mutableNode.children ?? []
                    
                    // Group USB accessories cleanly, but keep Displays at the top level of the TB Hub
                    var displays: [DeviceNode] = []
                    var usbs: [DeviceNode] = []
                    for acc in matchedAccessories {
                        if acc.iconName == "display" || acc.iconName == "rectangle.stack.fill" || acc.iconName == "laptopcomputer" {
                            displays.append(acc)
                        } else {
                            usbs.append(acc)
                        }
                    }
                    
                    newChildren.append(contentsOf: displays)
                    if !usbs.isEmpty {
                        let totalCons = sumBandwidth(of: usbs)
                        let totalLabel = formatTotalBandwidth(totalCons)
                        
                        let accessoriesFolder = DeviceNode(id: UUID(), name: "USB Accessories", iconName: "cable.connector", bandwidthLabel: totalLabel, uid: nil, children: usbs)
                        newChildren.append(accessoriesFolder)
                    }
                    
                    mutableNode.children = newChildren
                }
            }
            newNodes.append(mutableNode)
        }
        return newNodes
    }
    
    private func sumBandwidth(of nodes: [DeviceNode]) -> Double {
        var total: Double = 0.0
        for node in nodes {
            if let children = node.children, !children.isEmpty {
                // To avoid double-counting hub uplinks and downstream devices, we only sum the leaf endpoints
                total += sumBandwidth(of: children)
            } else {
                if let label = node.bandwidthLabel {
                    if label.contains("Gbps") || label.contains("Gb/s") {
                        let valStr = label.replacingOccurrences(of: " Gbps", with: "").replacingOccurrences(of: " Gb/s", with: "")
                        total += Double(valStr) ?? 0.0
                    } else if label.contains("Mbps") || label.contains("Mb/s") {
                        let valStr = label.replacingOccurrences(of: " Mbps", with: "").replacingOccurrences(of: " Mb/s", with: "")
                        total += (Double(valStr) ?? 0.0) / 1000.0
                    }
                }
            }
        }
        return total
    }
    
    private func formatTotalBandwidth(_ total: Double) -> String {
        if total == 0.0 { return "0 Mbps" }
        if total >= 1.0 {
            return String(format: "%.1f Gbps", total)
        } else {
            return String(format: "%.0f Mbps", total * 1000.0)
        }
    }
    
    // Scours a tree recursively and permanently rips out any nodes that match the names array
    private func extractMatching(from nodes: [DeviceNode], accessories: [Accessory], extracted: inout [DeviceNode]) -> [DeviceNode] {
        var keptNodes: [DeviceNode] = []
        for node in nodes {
            var mutableNode = node
            
            var matchedAccessory: Accessory? = nil
            for acc in accessories {
                if mutableNode.name.localizedCaseInsensitiveContains(acc.name) {
                    matchedAccessory = acc
                    break
                }
            }
            
            if let acc = matchedAccessory {
                let newLabel = mutableNode.bandwidthLabel ?? acc.speed
                let finalNode = DeviceNode(id: mutableNode.id, name: mutableNode.name, iconName: mutableNode.iconName, bandwidthLabel: newLabel, uid: mutableNode.uid, children: mutableNode.children, dscActive: mutableNode.dscActive, displayDetails: mutableNode.displayDetails, rawBandwidth: mutableNode.rawBandwidth)
                extracted.append(finalNode)
            } else {
                if let children = mutableNode.children {
                    let remaining = extractMatching(from: children, accessories: accessories, extracted: &extracted)
                    mutableNode.children = remaining.isEmpty ? nil : remaining
                }
                keptNodes.append(mutableNode)
            }
        }
        return keptNodes
    }
    
    private func hexToDec(_ hex: String) -> String? {
        let cleanHex = hex.replacingOccurrences(of: "0x", with: "")
        if let val = UInt64(cleanHex, radix: 16) {
            return String(val)
        }
        return nil
    }

    private func mapNodes(_ nodes: [SPNode], defaultIcon: String, dscDisplayNames: Set<String> = [], displayDetailsMap: [String: DisplayDetails] = [:]) -> [DeviceNode]? {
        guard !nodes.isEmpty else { return nil }
        
        var result: [DeviceNode] = []
        for node in nodes {
            var name = node._name ?? "Unknown Device"
            let uid = node.switch_uid_key // Needed for our topology mapper
            var children: [DeviceNode]? = nil
            var iconName = defaultIcon
            
            // 1. Clean up underlying bus connections and inject physical Port Mappings
            if name.hasPrefix("thunderboltusb4_bus_") || name.hasPrefix("thunderbolt_bus_") {
                let busStr = name.replacingOccurrences(of: "thunderboltusb4_bus_", with: "").replacingOccurrences(of: "thunderbolt_bus_", with: "")
                if let busID = Int(busStr) {
                    name = HardwareScanner.mapPhysicalPortLocation(forBus: busID)
                } else {
                    name = "Thunderbolt Port"
                }
            }
            
            // 2. Inject Vendor Names for generic labels (like "Thunderbolt Hub")
            if let vendor = node.vendor_name_key, vendor != "Apple Inc." {
                // Shorten some overly-long corporate names
                let shortVendor = vendor.replacingOccurrences(of: "Other World Computing", with: "OWC")
                                        .replacingOccurrences(of: " Technologies, Inc.", with: "")
                                        .replacingOccurrences(of: ", Inc.", with: "")
                
                // Only prepend if the device doesn't already have the brand in the name
                if !name.localizedCaseInsensitiveContains(shortVendor) {
                    name = "\(shortVendor) \(name)"
                }
            }
            
            if node.spdisplays_connection_type == "spdisplays_internal" {
                name = "Built-In Display"
                iconName = "laptopcomputer"
            }
            
            if let items = node._items {
                children = mapNodes(items, defaultIcon: defaultIcon, dscDisplayNames: dscDisplayNames, displayDetailsMap: displayDetailsMap)
            }
            
            var bwLabel: String? = nil
            var isDSC = false
            var rawBw: Double? = nil
            var displayDetails: DisplayDetails? = nil
            var peripheralDetails: PeripheralDetails? = nil

            if let res = node._spdisplays_resolution {
                let cleanRes = res.replacingOccurrences(of: ".00Hz", with: "Hz")

                // Check by name BEFORE appending the resolution string
                isDSC = dscDisplayNames.contains { dscName in
                    name.localizedCaseInsensitiveContains(dscName) || dscName.localizedCaseInsensitiveContains(name)
                }

                name = "\(name) (\(cleanRes))"

                if let bw = self.calculateDisplayBandwidth(res, dscActive: isDSC) {
                    bwLabel = String(format: "%.1f Gbps", bw)
                    if isDSC {
                        rawBw = bw * 3.0  // Store uncompressed value
                    }
                }

                // Build DisplayDetails from actual system_profiler fields (decoded via CodingKeys)
                let nativePixels   = node.displayPixels
                let vendorName     = vendorNameFromID(node.displayVendorId)
                let productModel   = node.displayProductId.map { "0x\($0.uppercased())" }
                let serialDecoded  = decodeSerial(node.displaySerialHex)
                let mfgDate        = buildMfgDate(week: node.displayWeek, year: node.displayYear)
                let displayIdStr   = node.displayIDNumber.map { "Display \($0)" }
                let resLabel       = parseResolutionLabel(node.spdisplays_pixelresolution)
                let connType       = parseConnectionType(node.spdisplays_connection_type)
                let isMain         = node.spdisplays_main == "spdisplays_yes"

                // Best-effort IORegistry augmentation (DSC version, etc.)
                var ioDetails: DisplayDetails? = nil
                let baseName = node._name ?? ""
                for (detailName, details) in displayDetailsMap {
                    if baseName.localizedCaseInsensitiveContains(detailName) || detailName.localizedCaseInsensitiveContains(baseName) {
                        ioDetails = details
                        break
                    }
                }

                displayDetails = DisplayDetails(
                    displayUID: displayIdStr ?? ioDetails?.displayUID,
                    vendor: vendorName ?? ioDetails?.vendor,
                    model: productModel ?? ioDetails?.model,
                    connectionType: connType ?? ioDetails?.connectionType,
                    bitDepth: ioDetails?.bitDepth,
                    nativeResolution: nativePixels ?? ioDetails?.nativeResolution,
                    isScaled: isMain ? false : nil,
                    edidSerial: serialDecoded ?? ioDetails?.edidSerial,
                    edidMfgDate: mfgDate ?? ioDetails?.edidMfgDate,
                    dscVersion: ioDetails?.dscVersion,
                    dscMode: ioDetails?.dscMode,
                    dscRatio: isDSC ? "3:1" : nil,
                    maxResolution: resLabel ?? ioDetails?.maxResolution,
                    hdrSupport: ioDetails?.hdrSupport,
                    panelType: ioDetails?.panelType
                )
            } else if let speed = node.receptacle_upstream_ambiguous_tag?.current_speed_key ?? node.receptacle_1_tag?.current_speed_key {
                bwLabel = speed.contains("Up to") ? nil : speed
            }

            // Build peripheral details for non-display nodes
            if node._spdisplays_resolution == nil {
                // Collect downstream TB port statuses (ports 2–4 are downstream on hubs)
                var tbPorts: [TBPortStatus] = []
                for (portNum, tag) in [(2, node.receptacle_2_tag), (3, node.receptacle_3_tag), (4, node.receptacle_4_tag)] {
                    guard let t = tag else { continue }
                    let connected = t.receptacle_status_key == "receptacle_connected"
                    let portSpeed = t.current_speed_key ?? "Unknown"
                    tbPorts.append(TBPortStatus(portNumber: portNum, speed: portSpeed, isConnected: connected, firmwareVersion: t.micro_version_key))
                }

                let pd = PeripheralDetails(
                    vendor: node.vendor_name_key,
                    uid: uid,
                    vendorId: node.vendorId,
                    productId: node.productId,
                    serialNumber: node.serialNum,
                    speed: node.speed,
                    usbVersion: node.bcdUsb,
                    deviceVersion: node.bcdDevice,
                    powerAvailable: node.busPower,
                    powerUsed: node.busPowerUsed,
                    locationId: node.locationId,
                    tbDeviceId: node.device_id_key,
                    tbVendorId: node.vendor_id_key,
                    tbRevision: node.device_revision_key,
                    tbFirmware: node.switch_version_key,
                    tbMode: node.mode_key.map { Self.mapTBMode($0) },
                    tbRouteString: node.route_string_key,
                    tbDomainUUID: node.domain_uuid_key,
                    tbDownstreamPorts: tbPorts.isEmpty ? nil : tbPorts,
                    bsdName: nil
                )
                if pd.hasAnyDetail { peripheralDetails = pd }
            }

            result.append(DeviceNode(name: name, iconName: iconName, bandwidthLabel: bwLabel, uid: uid, children: children, dscActive: isDSC, displayDetails: displayDetails, rawBandwidth: rawBw, peripheralDetails: peripheralDetails))
        }
        return result.isEmpty ? nil : result
    }

    /// Converts a hex vendor ID to a brand name
    private func vendorNameFromID(_ hexId: String?) -> String? {
        guard let hex = hexId?.lowercased() else { return nil }
        let known: [String: String] = [
            "10ac": "Dell Inc.",
            "1e6d": "LG Electronics",
            "04e8": "Samsung",
            "04ca": "Asus",
            "0472": "ViewSonic",
            "04b3": "Lenovo",
            "038d": "EIZO",
            "0d2c": "Philips",
            "38c2": "MSI",
            "0452": "Micro-Star (MSI)",
            "0586": "ZHC / LG",
            "05ac": "Apple",
        ]
        return known[hex] ?? "Vendor 0x\(hex.uppercased())"
    }

    /// Decodes a hex serial string to ASCII if all bytes are printable, else returns hex
    private func decodeSerial(_ hexSerial: String?) -> String? {
        guard let hex = hexSerial, !hex.isEmpty else { return nil }
        var ascii = ""
        var idx = hex.startIndex
        while idx < hex.endIndex, hex.distance(from: idx, to: hex.endIndex) >= 2 {
            let next = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<next], radix: 16), byte >= 32, byte < 127 {
                ascii.append(Character(UnicodeScalar(byte)))
            } else {
                return hex.uppercased() // not clean ASCII — return raw hex
            }
            idx = next
        }
        return ascii.isEmpty ? hex.uppercased() : ascii
    }

    /// Builds a human-readable manufacture date from EDID week/year fields
    private func buildMfgDate(week: String?, year: String?) -> String? {
        guard let y = year else { return nil }
        if let w = week, let wn = Int(w) {
            // Each week is ~7.6 days; week 1 starts Jan 1
            let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
            let monthIdx = min(11, max(0, (wn - 1) * 12 / 52))
            return "\(months[monthIdx]) \(y)"
        }
        return y
    }

    /// Maps system_profiler resolution category codes to human-readable labels
    private func parseResolutionLabel(_ spKey: String?) -> String? {
        guard let key = spKey else { return nil }
        let map: [String: String] = [
            "spdisplays_uwqhd": "Ultra-Wide QHD",
            "spdisplays_4k":    "4K UHD",
            "spdisplays_5k":    "5K",
            "spdisplays_6k":    "6K",
            "spdisplays_8k":    "8K",
            "spdisplays_qhd":   "QHD",
            "spdisplays_wqhd":  "WQHD",
            "spdisplays_fhd":   "Full HD",
            "spdisplays_hd":    "HD",
            "spdisplays_wxga":  "WXGA",
        ]
        return map[key] ?? key.replacingOccurrences(of: "spdisplays_", with: "").uppercased()
    }

    /// Maps system_profiler connection type keys to human-readable strings
    private func parseConnectionType(_ spKey: String?) -> String? {
        guard let key = spKey else { return nil }
        switch key {
        case "spdisplays_displayport_connector":  return "DisplayPort"
        case "spdisplays_hdmi_connector":         return "HDMI"
        case "spdisplays_usbc_connector":         return "USB-C"
        case "spdisplays_thunderbolt":            return "Thunderbolt"
        case "spdisplays_internal":               return "Internal"
        case "spdisplays_dp_over_usbc":           return "DisplayPort (USB-C)"
        default: return key.replacingOccurrences(of: "spdisplays_", with: "").capitalized
        }
    }

    /// Maps system_profiler depth strings to human-readable bit depth
    private func parseBitDepth(_ spKey: String?) -> String? {
        guard let key = spKey else { return nil }
        switch key {
        case "CGSThirtytwoBitColor":             return "8-bit (32-bit color)"
        case "CGSSixtyFourBitColor":             return "10-bit (64-bit color)"
        case "CGSOnehundredtwentyeightBitColor": return "16-bit (128-bit color)"
        default:
            if key.contains("64") { return "10-bit" }
            if key.contains("32") { return "8-bit" }
            return key
        }
    }

    // Example resolution string: "3440 x 1440 @ 60.00Hz"
    private func calculateDisplayBandwidth(_ res: String, dscActive: Bool = false) -> Double? {
        let parts = res.replacingOccurrences(of: "Hz", with: "").components(separatedBy: .whitespaces)
        let numbers = parts.compactMap { Double($0) }

        if numbers.count >= 3 {
            let width = numbers[0]
            let height = numbers[1]
            let refresh = numbers[2]

            var bandwidth = (width * height * refresh * 24.0 * 1.2) / 1_000_000_000.0
            if dscActive {
                bandwidth /= 3.0  // DSC 1.2 achieves approximately 3:1 compression
            }
            return bandwidth
        }
        return nil
    }

    static func mapTBMode(_ key: String) -> String {
        switch key {
        case "usb_four":  return "USB4 / Thunderbolt 4"
        case "tb3":       return "Thunderbolt 3"
        case "tb2":       return "Thunderbolt 2"
        case "tb1":       return "Thunderbolt 1"
        case "usb_three": return "USB 3"
        default:          return key
        }
    }

    // Detect macOS Model and map internal bus indexes to literal chassis holes.
    static func mapPhysicalPortLocation(forBus bus: Int) -> String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        // Advanced Apple Silicon Pro/Max Chassis Port Detection lookup tables
        switch modelString {
        case "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11": // M2/M3 MacBook Pro 14"/16"
            if bus == 0 { return "Left Back Port" }
            if bus == 1 { return "Left Front Port" }
            if bus == 2 { return "Right Port" }
        case "Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14": // M1/M2 Mac Studio
            if bus == 0 { return "Back Port 1 (Top Left)" }
            if bus == 1 { return "Back Port 2" }
            if bus == 2 { return "Back Port 3" }
            if bus == 3 { return "Back Port 4 (Bottom Right)" }
            if bus == 4 { return "Front Port 1 (Left)" }
            if bus == 5 { return "Front Port 2 (Right)" }
        // Default generic heuristics based on architectural lineage
        default:
            if modelString.contains("MacBookPro") {
                if bus == 0 { return "Left Back Port" }
                if bus == 1 { return "Left Front Port" }
                if bus == 2 { return "Right Port" }
            } else if modelString.contains("MacBookAir") {
                if bus == 0 { return "Left Back Port" }
                if bus == 1 { return "Left Front Port" }
            } else if modelString.contains("Macmini") {
                if bus == 0 { return "Back Left Port" }
                if bus == 1 { return "Back Right Port" }
            }
        }
        
        return "Thunderbolt Port \(bus + 1)"
    }
}
