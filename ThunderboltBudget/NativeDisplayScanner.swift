import Foundation
import CoreGraphics
import IOKit

/// Native replacement for `system_profiler SPDisplaysDataType`: resolution and refresh from
/// CoreGraphics, identity (name, serial, manufacture date) from the registry's per-display EDID
/// attributes. Produces the same `SPNode` shape the pipeline already consumes.
nonisolated enum NativeDisplayScanner {

    /// A GPU-level root node whose `spdisplays_ndrvs` holds one node per online display.
    static func scan() -> [SPNode] {
        let attributes = edidAttributes()

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        var displays: [SPNode] = []
        for id in ids.prefix(Int(count)) {
            var node = SPNode()
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0

            // Match the registry's EDID record on vendor-agnostic identity: product ID + serial.
            let match = attributes.first { $0.productID == Int(model) && $0.serial == Int(serial) }
                ?? attributes.first { $0.productID == Int(model) }

            node._name = isBuiltIn ? "Color LCD" : (match?.productName ?? "Display \(id)")
            node.displayVendorId = String(vendor, radix: 16)
            node.displayProductId = String(model, radix: 16)
            node.displaySerialHex = String(serial, radix: 16)
            node.displayWeek = match?.week.map(String.init) ?? "0"
            node.displayYear = match?.year.map(String.init) ?? "0"
            node.displayIDNumber = String(id)
            node.spdisplays_main = CGDisplayIsMain(id) != 0 ? "spdisplays_yes" : nil
            node.spdisplays_mirror = CGDisplayIsInMirrorSet(id) != 0 ? "spdisplays_on" : "spdisplays_off"
            if isBuiltIn { node.spdisplays_connection_type = "spdisplays_internal" }

            if let mode = CGDisplayCopyDisplayMode(id) {
                let hz = mode.refreshRate > 0 ? mode.refreshRate : 60
                node._spdisplays_resolution = String(format: "%d x %d @ %.2fHz", mode.width, mode.height, hz)
                // The current mode's pixelWidth/Height is the HiDPI backing store (e.g. 5120 x 2880 for a
                // 4K panel set to "looks like 2560 x 1440"), not the panel. Report the panel's own size.
                let panel = nativePanelSize(id, current: mode)
                node.displayPixels = "\(panel.width) x \(panel.height)"
                node.spdisplays_pixelresolution = pixelResolutionKey(width: panel.width, height: panel.height, builtIn: isBuiltIn)
            }
            displays.append(node)
        }
        guard !displays.isEmpty else { return [] }

        var gpu = SPNode()
        gpu._name = "GPU"
        gpu.spdisplays_ndrvs = displays
        return [gpu]
    }

    /// The panel's physical resolution: the mode macOS flags as native, else the largest 1:1
    /// (non-HiDPI) mode, else the current mode's backing size.
    private static func nativePanelSize(_ id: CGDirectDisplayID, current: CGDisplayMode) -> (width: Int, height: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let kDisplayModeNativeFlag: UInt32 = 0x0200_0000 // IOGraphicsTypes.h
        if let native = modes.first(where: { $0.ioFlags & kDisplayModeNativeFlag != 0 }) {
            return (native.pixelWidth, native.pixelHeight)
        }
        if let largest = modes.filter({ $0.width == $0.pixelWidth })
            .max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) {
            return (largest.pixelWidth, largest.pixelHeight)
        }
        return (current.pixelWidth, current.pixelHeight)
    }

    // MARK: - Registry EDID attributes

    private struct EDIDAttributes {
        let productName: String?
        let productID: Int
        let serial: Int
        let week: Int?
        let year: Int?
    }

    private static func edidAttributes() -> [EDIDAttributes] {
        var result: [EDIDAttributes] = []
        let nodes = IOKitRegistry.services(matchingClass: "AppleCLCD2")
        defer { IOKitRegistry.release(nodes) }
        for n in nodes {
            guard let attrs = n.dict("DisplayAttributes"),
                  let product = attrs["ProductAttributes"] as? [String: Any],
                  let pid = (product["ProductID"] as? NSNumber)?.intValue else { continue }
            result.append(EDIDAttributes(
                productName: product["ProductName"] as? String,
                productID: pid,
                serial: (product["SerialNumber"] as? NSNumber)?.intValue ?? 0,
                week: (product["WeekOfManufacture"] as? NSNumber)?.intValue,
                year: (product["YearOfManufacture"] as? NSNumber)?.intValue
            ))
        }
        return result
    }

    /// Maps native pixel dimensions to the `spdisplays_*` class keys the pipeline already labels.
    private static func pixelResolutionKey(width: Int, height: Int, builtIn: Bool) -> String {
        if builtIn { return "\(width) x \(height) Retina" }
        switch (width, height) {
        case (3440, 1440), (6880, 2880): return "spdisplays_uwqhd"
        case (3840, 2160): return "spdisplays_4k"
        case (5120, 2880): return "spdisplays_5k"
        case (6016, 3384): return "spdisplays_6k"
        case (7680, 4320): return "spdisplays_8k"
        case (2560, 1440): return "spdisplays_qhd"
        case (1920, 1080): return "spdisplays_fhd"
        case (1280, 720):  return "spdisplays_hd"
        default: return "\(width) x \(height)"
        }
    }
}
