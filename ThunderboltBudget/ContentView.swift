import SwiftUI
import AppKit
import Charts

struct ContentView: View {
    @ObservedObject var manager = HardwareManager.shared
    @ObservedObject var analytics = LiveAnalytics.shared
    @State private var selectedDisplayId: UUID? = nil
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                mainContent

                // Detail Panel — fixed width, not user-resizable, so it can never collapse
                // the main content (NavigationSplitView's sidebar drag-to-collapse did exactly that).
                if let displayId = selectedDisplayId, let selectedNode = findNodeById(displayId, in: manager.deviceTrees) {
                    Divider()
                    DeviceDetailPanel(node: selectedNode, onClose: { selectedDisplayId = nil })
                        .frame(minWidth: 320, maxWidth: 400)
                }
            }
            .navigationTitle("Thunderbolt Bandwidth Budget")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: manager.performScan) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: manager.copyMarkdownAction) {
                        Label("Copy Markdown", systemImage: "doc.on.clipboard")
                    }
                    .disabled(manager.deviceTrees.isEmpty || manager.isScanning)
                }
                ToolbarItem(placement: .automatic) {
                    Picker("Appearance", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: { openSettings() }) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 850)
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            // Total System Header
            if !manager.deviceTrees.isEmpty, !manager.isScanning {
                let total = manager.gatherSystemTotal()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total System Framework")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f Gbps", total))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                    }
                    Spacer()
                }
                .padding()

                Divider()

                LiveTrafficChart(analytics: analytics)

                Divider()
            }

            // The Main Interactive Content Window
            if manager.deviceTrees.isEmpty || manager.isScanning {
                VStack(spacing: 12) {
                    if manager.isScanning {
                        ProgressView("Scanning Thunderbolt Bus...")
                    } else {
                        Text("No hardware detected.")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(manager.deviceTrees) { node in
                        DeviceNodeView(node: node, expandedNodes: $manager.expandedNodes, selectedDisplayId: $selectedDisplayId)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func findNodeById(_ id: UUID, in nodes: [DeviceNode]) -> DeviceNode? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if let children = node.children, let found = findNodeById(id, in: children) {
                return found
            }
        }
        return nil
    }
}

struct DeviceNodeView: View {
    let node: DeviceNode
    @Binding var expandedNodes: Set<UUID>
    @Binding var selectedDisplayId: UUID?

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedNodes.contains(node.id) },
                    set: { isExpanding in
                        if isExpanding {
                            expandedNodes.insert(node.id)
                        } else {
                            expandedNodes.remove(node.id)
                        }
                    }
                )
            ) {
                ForEach(children) { child in
                    DeviceNodeView(node: child, expandedNodes: $expandedNodes, selectedDisplayId: $selectedDisplayId)
                }
            } label: {
                DeviceRow(node: node, selectedDisplayId: $selectedDisplayId)
            }
        } else {
            DeviceRow(node: node, selectedDisplayId: $selectedDisplayId)
        }
    }
}

struct DeviceRow: View {
    let node: DeviceNode
    @Binding var selectedDisplayId: UUID?
    @ObservedObject private var liveAnalytics = LiveAnalytics.shared

    var isClickable: Bool {
        return node.displayDetails != nil || node.peripheralDetails != nil
    }

    var isSelected: Bool {
        return selectedDisplayId == node.id
    }

    // Real, currently-measured throughput (from iostat/netstat), as opposed to bandwidthLabel's
    // static negotiated-link "budget" figure. nil when this node has no storage/network descendant.
    var liveGbps: Double? {
        liveAnalytics.liveGbps(for: node)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: node.iconName)
                    .foregroundColor(.blue)

                Text(node.name)
                    .font(.system(.body, design: .rounded))

                if node.dscActive {
                    Text("DSC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .glassEffect(.regular.tint(.purple), in: .capsule)
                }

                Spacer()

                if let live = liveGbps {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text(Self.liveLabel(live))
                            .font(.caption2.bold())
                    }
                    .foregroundColor(.mint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.tint(.mint), in: .capsule)
                }

                if let bw = node.bandwidthLabel {
                    Text(bw)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(pillColor(for: node))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }

            if let ratio = node.bandwidthRatio {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))

                        Rectangle()
                            .fill(pillColor(for: node))
                            .frame(width: max(0, min(CGFloat(ratio), 1.0) * geo.size.width))
                    }
                }
                .frame(height: 4)
                .cornerRadius(2)
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .onTapGesture {
            if isClickable {
                selectedDisplayId = isSelected ? nil : node.id
            }
        }
    }

    private func pillColor(for node: DeviceNode) -> Color {
        guard let ratio = node.bandwidthRatio else {
            return Color.blue.opacity(0.8)
        }
        if ratio >= 0.80 { return Color.red }
        else if ratio >= 0.50 { return Color.orange }
        else { return Color.green }
    }

    static func liveLabel(_ gbps: Double) -> String {
        if gbps >= 1.0 { return String(format: "%.2f Gbps", gbps) }
        return String(format: "%.0f Mbps", gbps * 1000)
    }
}

struct LiveTrafficChart: View {
    @ObservedObject var analytics: LiveAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Data Throughput")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Chart {
                ForEach(Array(analytics.totalTrafficGbps.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("Time", index),
                        y: .value("Gbps", value)
                    )
                    .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.blue.opacity(0.6), .blue.opacity(0.0)]), startPoint: .top, endPoint: .bottom))

                    LineMark(
                        x: .value("Time", index),
                        y: .value("Gbps", value)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis(.hidden)
            // Fix theoretical maximum to 40 Gbps, but allow scaling if somehow exceeded
            .chartYScale(domain: 0...max(40.0, (analytics.totalTrafficGbps.max() ?? 40.0) + 5))
            .frame(height: 120)
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}

struct DeviceDetailPanel: View {
    let node: DeviceNode
    let onClose: () -> Void
    @ObservedObject private var liveAnalytics = LiveAnalytics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: node.iconName)
                    .foregroundColor(.blue)
                Text("Details")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(.regularMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Text(node.name)
                            .font(.body)
                    }

                    if let bw = node.bandwidthLabel {
                        Divider()
                        DetailRowView(label: "Bandwidth", value: bw)
                    }

                    if let live = liveAnalytics.liveGbps(for: node) {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Live Throughput")
                                    .font(.caption.bold())
                                    .foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundColor(.mint)
                                    Text("Measured, not budget")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(DeviceRow.liveLabel(live))
                                .font(.title3.bold())
                                .foregroundColor(.mint)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Color.mint.opacity(0.08))
                        .cornerRadius(6)
                    }

                    if node.dscActive {
                        Divider()
                        DSCDetailSection(node: node)
                    }

                    if let details = node.displayDetails {
                        Divider()
                        DisplayInfoSection(node: node, details: details)
                        Divider()
                        TechnicalDetailsSection(details: details)
                    }

                    if let details = node.peripheralDetails {
                        Divider()
                        PeripheralInfoSection(details: details)
                    }

                    Spacer()
                }
                .padding()
            }
        }
    }
}

struct DSCDetailSection: View {
    let node: DeviceNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DSC Status")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Active")
                        .font(.caption.bold())
                }
            }

            if let raw = node.rawBandwidth, let compressed = Double(node.bandwidthLabel?.replacingOccurrences(of: " Gbps", with: "") ?? "") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Effective")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1f Gbps", compressed))
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                    }
                    HStack {
                        Text("Raw (uncompressed)")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1f Gbps", raw))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Compression")
                            .font(.caption)
                        Spacer()
                        Text("3:1")
                            .font(.caption.bold())
                            .foregroundColor(.purple)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color.purple.opacity(0.05))
                .cornerRadius(6)
            }
        }
    }
}

struct DisplayInfoSection: View {
    let node: DeviceNode
    let details: DisplayDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display Information")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            DetailRowView(label: "Resolution", value: node.name.extractResolution() ?? "N/A")
            if let native = details.nativeResolution {
                DetailRowView(label: "Native Pixels", value: native)
            }
            if let type_ = details.maxResolution {
                DetailRowView(label: "Display Type", value: type_)
            }
            if let conn = details.connectionType {
                DetailRowView(label: "Connection", value: conn)
            }
            if let vendor = details.vendor {
                DetailRowView(label: "Vendor", value: vendor)
            }
            if let model = details.model {
                DetailRowView(label: "Product ID", value: model)
            }
        }
    }
}

struct TechnicalDetailsSection: View {
    let details: DisplayDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Technical Details")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            if let uid = details.displayUID {
                DetailRowView(label: "Display ID", value: uid)
            }
            if let serial = details.edidSerial {
                DetailRowView(label: "Serial", value: serial)
            }
            if let mfg = details.edidMfgDate {
                DetailRowView(label: "Manufactured", value: mfg)
            }
            if let dscV = details.dscVersion {
                DetailRowView(label: "DSC Version", value: dscV)
            }
            if let dscM = details.dscMode {
                DetailRowView(label: "DSC Mode", value: dscM)
            }
            if let hdr = details.hdrSupport {
                DetailRowView(label: "HDR", value: hdr)
            }
            if let panel = details.panelType {
                DetailRowView(label: "Panel Type", value: panel)
            }
        }
    }
}

struct PeripheralInfoSection: View {
    let details: PeripheralDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // --- Thunderbolt section ---
            let hasTB = [details.tbMode, details.tbDeviceId, details.tbVendorId,
                         details.tbRevision, details.tbFirmware, details.tbRouteString,
                         details.tbDomainUUID].contains { $0 != nil } || details.tbDownstreamPorts != nil
            if hasTB {
                Text("Thunderbolt")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                if let vendor = details.vendor {
                    DetailRowView(label: "Vendor", value: vendor)
                }
                if let mode = details.tbMode {
                    DetailRowView(label: "Mode", value: mode)
                }
                if let fw = details.tbFirmware {
                    DetailRowView(label: "Firmware", value: fw)
                }
                if let devId = details.tbDeviceId {
                    DetailRowView(label: "Device ID", value: devId)
                }
                if let vendId = details.tbVendorId {
                    DetailRowView(label: "Vendor ID", value: vendId)
                }
                if let rev = details.tbRevision {
                    DetailRowView(label: "Revision", value: rev)
                }
                if let route = details.tbRouteString {
                    DetailRowView(label: "Route", value: route)
                }
                if let uid = details.uid {
                    DetailRowView(label: "UID", value: uid)
                }
                if let uuid = details.tbDomainUUID {
                    DetailRowView(label: "Domain UUID", value: uuid)
                }
                if let ports = details.tbDownstreamPorts, !ports.isEmpty {
                    Divider()
                    Text("Daisy-Chain Ports")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    ForEach(ports, id: \.portNumber) { port in
                        HStack {
                            Text("Port \(port.portNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if port.isConnected {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                Text(port.speed)
                                    .font(.caption.bold())
                            } else {
                                Circle()
                                    .fill(Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text("Empty")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // --- USB section ---
            let hasUSB = [details.speed, details.usbVersion, details.deviceVersion,
                          details.vendorId, details.productId, details.serialNumber,
                          details.powerUsed, details.locationId].contains { $0 != nil }
            if hasUSB {
                if hasTB { Divider() }
                Text("USB")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                if !hasTB, let vendor = details.vendor {
                    DetailRowView(label: "Vendor", value: vendor)
                }
                if let speed = details.speed {
                    DetailRowView(label: "Speed", value: speed)
                }
                if let usbVersion = details.usbVersion {
                    DetailRowView(label: "USB Version", value: usbVersion)
                }
                if let deviceVersion = details.deviceVersion {
                    DetailRowView(label: "Device Version", value: deviceVersion)
                }
                if let vendorId = details.vendorId {
                    DetailRowView(label: "Vendor ID", value: vendorId)
                }
                if let productId = details.productId {
                    DetailRowView(label: "Product ID", value: productId)
                }
                if let serial = details.serialNumber {
                    DetailRowView(label: "Serial", value: serial)
                }
                if let powerUsed = details.powerUsed {
                    let powerStr = details.powerAvailable.map { "\(powerUsed) / \($0)" } ?? powerUsed
                    DetailRowView(label: "Power", value: powerStr)
                }
                if !hasTB, let uid = details.uid {
                    DetailRowView(label: "UID", value: uid)
                }
                if let locationId = details.locationId {
                    DetailRowView(label: "Location ID", value: locationId)
                }
            }
        }
    }
}

struct DetailRowView: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
}

extension String {
    func extractResolution() -> String? {
        let pattern = #"(\d+)\s*x\s*(\d+)\s*@\s*([\d.]+)Hz"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(self.startIndex..., in: self)
            if let match = regex.firstMatch(in: self, range: range) {
                if let widthRange = Range(match.range(at: 1), in: self),
                   let heightRange = Range(match.range(at: 2), in: self),
                   let refreshRange = Range(match.range(at: 3), in: self) {
                    let width = String(self[widthRange])
                    let height = String(self[heightRange])
                    let refresh = String(self[refreshRange])
                    return "\(width) × \(height) @ \(refresh) Hz"
                }
            }
        }
        return nil
    }
}
