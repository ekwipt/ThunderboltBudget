import Foundation
import IOKit

/// Thin, sandbox-safe wrapper over the IOKit registry. Replaces shelling out to `ioreg`.
/// Everything here is read-only and uses only public IOKit APIs.
nonisolated struct IORegistryNode {
    let entry: io_registry_entry_t
    let name: String
    let className: String
    let properties: [String: Any]

    subscript(key: String) -> Any? { properties[key] }

    func string(_ key: String) -> String? { properties[key] as? String }
    func int(_ key: String) -> Int? { (properties[key] as? NSNumber)?.intValue }
    func uint64(_ key: String) -> UInt64? { (properties[key] as? NSNumber)?.uint64Value }
    func dict(_ key: String) -> [String: Any]? { properties[key] as? [String: Any] }
    func data(_ key: String) -> Data? { properties[key] as? Data }
}

nonisolated enum IOKitRegistry {

    /// All services matching an IOKit class name (including subclasses), with properties loaded.
    /// The returned nodes hold retained registry entries; call `release(_:)` when done.
    static func services(matchingClass className: String) -> [IORegistryNode] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [IORegistryNode] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let node = node(for: entry) {
                result.append(node)
            } else {
                IOObjectRelease(entry)
            }
        }
        return result
    }

    static func node(for entry: io_registry_entry_t) -> IORegistryNode? {
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &nameBuf)
        var classBuf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &classBuf)
        return IORegistryNode(entry: entry, name: String(cString: nameBuf), className: String(cString: classBuf), properties: dict)
    }

    /// Children in the IOService plane.
    static func children(of node: IORegistryNode, plane: String = kIOServicePlane) -> [IORegistryNode] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(node.entry, plane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [IORegistryNode] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let child = Self.node(for: entry) { result.append(child) } else { IOObjectRelease(entry) }
        }
        return result
    }

    static func parent(of node: IORegistryNode, plane: String = kIOServicePlane) -> IORegistryNode? {
        var parentEntry: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(node.entry, plane, &parentEntry) == KERN_SUCCESS else { return nil }
        if let p = Self.node(for: parentEntry) { return p }
        IOObjectRelease(parentEntry)
        return nil
    }

    static func release(_ nodes: [IORegistryNode]) {
        for n in nodes { IOObjectRelease(n.entry) }
    }
}

/// Depth-first traversal of the whole IOService plane, in the same order and with the same entry
/// names (`name@location`) that `ioreg -l` prints. Replaces parsing `ioreg -l` text.
nonisolated enum IORegistryWalker {

    /// Visits every registry entry. `path` holds the display names of all ancestors followed by the
    /// entry's own name (outermost first), mirroring the indentation hierarchy of `ioreg -l`.
    static func walk(_ visit: (_ node: IORegistryNode, _ path: [String]) -> Void) {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        var path: [String] = []
        walk(entry: root, path: &path, visit: visit)
    }

    private static func walk(entry: io_registry_entry_t, path: inout [String], visit: (IORegistryNode, [String]) -> Void) {
        guard let node = IOKitRegistry.node(for: entry) else { return }
        defer { /* `entry` is released by the caller that obtained it, except the root */ }

        var locationBuf = [CChar](repeating: 0, count: 128)
        let hasLocation = IORegistryEntryGetLocationInPlane(entry, kIOServicePlane, &locationBuf) == KERN_SUCCESS
        let location = hasLocation ? String(cString: locationBuf) : ""
        let displayName = location.isEmpty ? node.name : "\(node.name)@\(location)"

        path.append(displayName)
        visit(node, path)

        var iterator: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS {
            while case let child = IOIteratorNext(iterator), child != 0 {
                walk(entry: child, path: &path, visit: visit)
                IOObjectRelease(child)
            }
            IOObjectRelease(iterator)
        }
        path.removeLast()
    }
}
