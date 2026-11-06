import Foundation
import IOKit

/// Cumulative I/O counters read natively (no `iostat` / `netstat` subprocesses).
/// Callers diff successive readings to get rates.
nonisolated enum NativeLiveStats {

    /// Whole-disk BSD name ("disk4") → cumulative bytes read + written, from each
    /// IOBlockStorageDriver's `Statistics` dictionary (the same counters `iostat` reports).
    static func diskCumulativeBytes() -> [String: Double] {
        var result: [String: Double] = [:]
        let drivers = IOKitRegistry.services(matchingClass: "IOBlockStorageDriver")
        defer { IOKitRegistry.release(drivers) }
        for driver in drivers {
            guard let stats = driver.dict("Statistics") else { continue }
            let read = (stats["Bytes (Read)"] as? NSNumber)?.doubleValue ?? 0
            let written = (stats["Bytes (Write)"] as? NSNumber)?.doubleValue ?? 0
            let media = IOKitRegistry.children(of: driver)
            defer { IOKitRegistry.release(media) }
            for m in media where m.className == "IOMedia" && (m["Whole"] as? Bool) == true {
                if let bsd = m.string("BSD Name") { result[bsd] = read + written }
            }
        }
        return result
    }

    struct NetCounters { var inBytes: UInt64; var outBytes: UInt64 }

    /// Bytes counted between two readings of a counter that the kernel may expose as only its
    /// low 32 bits (observed on current macOS: the routing-table sysctl's byte counters wrap at
    /// 2^32 even though the field is 64-bit). Handles that wrap; unambiguous while less than 4 GiB
    /// passes between readings (~17 Gbps at a 2 s interval).
    static func counterDelta(from previous: UInt64, to current: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        if previous <= UInt64(UInt32.max) && current <= UInt64(UInt32.max) {
            return current + (UInt64(UInt32.max) + 1) - previous
        }
        return 0
    }

    /// Interface name ("en5") → cumulative in/out byte counters, read from the routing-table
    /// sysctl (NET_RT_IFLIST2), the same source `netstat -ib` uses.
    static func networkCumulativeBytes() -> [String: NetCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, 6 /* NET_RT_IFLIST2 */, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: NetCounters] = [:]
        // Fixed layout of `struct if_msghdr2` (xnu net/if.h): 32-byte header, then `if_data64`
        // (packed to 4 bytes) whose ifi_ibytes / ifi_obytes sit at offsets 64 / 72 within it (ifi_baudrate is 64-bit).
        // Read at explicit offsets: Swift's import of the packed struct mis-reads the 64-bit fields.
        let headerSize = 32
        let ibytesOffset = headerSize + 64
        let obytesOffset = headerSize + 72
        let minMessageSize = headerSize + 80
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + 4 <= length {
                let msgLen = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard msgLen > 0 else { break }
                let type = raw[offset + 3]
                if type == 0x12 /* RTM_IFINFO2 */, msgLen >= minMessageSize, offset + minMessageSize <= length {
                    let index = raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt16.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(index), &nameBuf) != nil {
                        let inBytes = raw.loadUnaligned(fromByteOffset: offset + ibytesOffset, as: UInt64.self)
                        let outBytes = raw.loadUnaligned(fromByteOffset: offset + obytesOffset, as: UInt64.self)
                        let name = String(cString: nameBuf)
                        let candidate = NetCounters(inBytes: inBytes, outBytes: outBytes)
                        if let existing = result[name], existing.inBytes + existing.outBytes >= candidate.inBytes + candidate.outBytes { /* keep */ }
                        else { result[name] = candidate }
                    }
                }
                offset += msgLen
            }
        }
        return result
    }
}
