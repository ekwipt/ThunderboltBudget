import Testing
import Foundation
@testable import ThunderboltBudget

struct RegistryHelpersTests {

    @Test func physicalDiskDetection() {
        #expect(RegistryHelpers.isPhysicalDisk("disk4"))
        #expect(!RegistryHelpers.isPhysicalDisk("disk4s1"))
        #expect(!RegistryHelpers.isPhysicalDisk("disk"))
        #expect(!RegistryHelpers.isPhysicalDisk("en5"))
    }

    @Test func genericAncestorNamesAreRejected() {
        #expect(!RegistryHelpers.isRealProductName("USB3.0 Hub"))
        #expect(!RegistryHelpers.isRealProductName("AppleUSBHostController"))
        #expect(!RegistryHelpers.isRealProductName("IOMedia"))
        #expect(RegistryHelpers.isRealProductName("Samsung T7"))
    }

    @Test func bcdVersionStrings() {
        #expect(RegistryHelpers.bcdToVersionString(0x0320) == "3.2")
        #expect(RegistryHelpers.bcdToVersionString(0x0200) == "2.0")
    }

    @Test func usbSpeedNames() {
        #expect(RegistryHelpers.usbSpeedString(3) == "5 Gbps (SuperSpeed)")
        #expect(RegistryHelpers.usbSpeedString(99) == "Unknown")
    }
}

struct NativeLiveStatsTests {

    @Test func counterDeltaNormal() {
        #expect(NativeLiveStats.counterDelta(from: 100, to: 250) == 150)
        #expect(NativeLiveStats.counterDelta(from: 5, to: 5) == 0)
    }

    @Test func counterDeltaHandles32BitWrap() {
        // Counter wrapped past 2^32 between readings: 4_294_967_000 -> 700 is 996 bytes.
        #expect(NativeLiveStats.counterDelta(from: 4_294_967_000, to: 700) == 996)
    }

    @Test func counterDeltaIgnoresImpossibleDecrease() {
        // A decrease from a value already above 32 bits can't be a wrap; report nothing.
        #expect(NativeLiveStats.counterDelta(from: 10_000_000_000, to: 5) == 0)
    }

    @Test func networkCountersIncludeLoopback() {
        let counters = NativeLiveStats.networkCumulativeBytes()
        #expect(counters["lo0"] != nil)
    }

    @Test func diskCountersIncludeBootDisk() {
        #expect(NativeLiveStats.diskCumulativeBytes()["disk0"] != nil)
    }
}

struct NativeScannerTests {

    @Test func scanCompletesQuicklyWithoutSubprocesses() {
        // Everything is native now; a full scan used to take ~16 s because of system_profiler.
        let start = Date()
        _ = HardwareScanner().scanForDevices()
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func thunderboltHostsAreNamedByBus() {
        for node in NativeThunderboltScanner.scan() {
            #expect(node._name?.hasPrefix("thunderboltusb4_bus_") == true)
        }
    }

    @Test func displaysReportResolution() {
        for gpu in NativeDisplayScanner.scan() {
            for display in gpu.spdisplays_ndrvs ?? [] {
                #expect(display._spdisplays_resolution?.contains(" x ") == true)
            }
        }
    }
}
