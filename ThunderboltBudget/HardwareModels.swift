import Foundation

struct SPProfileRoot: Codable {
    var SPThunderboltDataType: [SPNode]?
    var SPUSBDataType: [SPNode]?
    var SPDisplaysDataType: [SPNode]?
}

struct SPNode: Codable {
    var _name: String?
    var _items: [SPNode]?
    var spdisplays_ndrvs: [SPNode]?

    // Thunderbolt/USB bandwidth keys
    var _spdisplays_resolution: String?
    var receptacle_upstream_ambiguous_tag: ReceptacleTag?
    var receptacle_1_tag: ReceptacleTag?
    var switch_uid_key: String?
    var spdisplays_connection_type: String?
    var vendor_name_key: String?

    // Display detail keys — many use hyphens so need explicit CodingKeys
    var displayPixels: String?         // native pixel resolution "3440 x 1440"
    var displayVendorId: String?       // hex vendor ID "10ac"
    var displayProductId: String?      // hex product ID "a185"
    var displaySerialHex: String?      // hex serial bytes "3035454c"
    var displayWeek: String?           // EDID manufacture week "42"
    var displayYear: String?           // EDID manufacture year "2020"
    var displayIDNumber: String?       // system display ID "3"
    var spdisplays_pixelresolution: String?  // resolution label "spdisplays_uwqhd"
    var spdisplays_main: String?             // "spdisplays_yes" if primary display
    var spdisplays_mirror: String?           // mirror state

    // USB device fields
    var vendorId: String?
    var productId: String?
    var serialNum: String?
    var speed: String?
    var bcdDevice: String?
    var bcdUsb: String?
    var busPower: String?
    var busPowerUsed: String?
    var locationId: String?

    // Thunderbolt device fields
    var device_id_key: String?
    var device_revision_key: String?
    var switch_version_key: String?
    var vendor_id_key: String?
    var route_string_key: String?
    var mode_key: String?
    var domain_uuid_key: String?
    var receptacle_2_tag: ReceptacleTag?
    var receptacle_3_tag: ReceptacleTag?
    var receptacle_4_tag: ReceptacleTag?

    enum CodingKeys: String, CodingKey {
        case _name = "_name"
        case _items = "_items"
        case spdisplays_ndrvs = "spdisplays_ndrvs"
        case _spdisplays_resolution = "_spdisplays_resolution"
        case receptacle_upstream_ambiguous_tag = "receptacle_upstream_ambiguous_tag"
        case receptacle_1_tag = "receptacle_1_tag"
        case switch_uid_key = "switch_uid_key"
        case spdisplays_connection_type = "spdisplays_connection_type"
        case vendor_name_key = "vendor_name_key"
        case displayPixels        = "_spdisplays_pixels"
        case displayVendorId      = "_spdisplays_display-vendor-id"
        case displayProductId     = "_spdisplays_display-product-id"
        case displaySerialHex     = "_spdisplays_display-serial-number"
        case displayWeek          = "_spdisplays_display-week"
        case displayYear          = "_spdisplays_display-year"
        case displayIDNumber      = "_spdisplays_displayID"
        case spdisplays_pixelresolution = "spdisplays_pixelresolution"
        case spdisplays_main      = "spdisplays_main"
        case spdisplays_mirror    = "spdisplays_mirror"
        case vendorId             = "vendor_id"
        case productId            = "product_id"
        case serialNum            = "serial_num"
        case speed                = "speed"
        case bcdDevice            = "bcd_device"
        case bcdUsb               = "bcd_usb"
        case busPower             = "bus_power"
        case busPowerUsed         = "bus_power_used"
        case locationId           = "location_id"
        case device_id_key        = "device_id_key"
        case device_revision_key  = "device_revision_key"
        case switch_version_key   = "switch_version_key"
        case vendor_id_key        = "vendor_id_key"
        case route_string_key     = "route_string_key"
        case mode_key             = "mode_key"
        case domain_uuid_key      = "domain_uuid_key"
        case receptacle_2_tag     = "receptacle_2_tag"
        case receptacle_3_tag     = "receptacle_3_tag"
        case receptacle_4_tag     = "receptacle_4_tag"
    }
}

struct ReceptacleTag: Codable {
    var current_speed_key: String?
    var link_status_key: String?
    var micro_version_key: String?
    var receptacle_status_key: String?
}

struct DisplayDetails: Hashable {
    let displayUID: String?
    let vendor: String?
    let model: String?
    let connectionType: String?
    let bitDepth: String?
    let nativeResolution: String?
    let isScaled: Bool?
    let edidSerial: String?
    let edidMfgDate: String?
    let dscVersion: String?
    let dscMode: String?
    let dscRatio: String?
    let maxResolution: String?
    let hdrSupport: String?
    let panelType: String?
}

struct TBPortStatus: Hashable {
    let portNumber: Int
    let speed: String
    let isConnected: Bool
    let firmwareVersion: String?
}

struct PeripheralDetails: Hashable {
    // Common
    let vendor: String?
    let uid: String?

    // USB
    let vendorId: String?
    let productId: String?
    let serialNumber: String?
    let speed: String?
    let usbVersion: String?
    let deviceVersion: String?
    let powerAvailable: String?
    let powerUsed: String?
    let locationId: String?

    // Thunderbolt
    let tbDeviceId: String?
    let tbVendorId: String?
    let tbRevision: String?
    let tbFirmware: String?
    let tbMode: String?
    let tbRouteString: String?
    let tbDomainUUID: String?
    let tbDownstreamPorts: [TBPortStatus]?

    // BSD identifier (e.g. "disk4", "en5") used to correlate this device with live iostat/netstat throughput
    let bsdName: String?

    var hasAnyDetail: Bool {
        let strings: [String?] = [vendor, uid, vendorId, productId, serialNumber, speed,
                                   usbVersion, deviceVersion, powerAvailable, powerUsed,
                                   locationId, tbDeviceId, tbVendorId, tbRevision,
                                   tbFirmware, tbMode, tbRouteString, tbDomainUUID]
        return strings.contains { $0 != nil } || tbDownstreamPorts != nil
    }
}

struct DeviceNode: Identifiable, Hashable {
    let id: UUID
    let name: String
    let iconName: String
    let bandwidthLabel: String?
    let uid: String?
    var children: [DeviceNode]?
    var bandwidthRatio: Double?
    var dscActive: Bool
    var displayDetails: DisplayDetails?
    var rawBandwidth: Double?  // Uncompressed bandwidth for displays with DSC
    var peripheralDetails: PeripheralDetails?

    init(id: UUID = UUID(), name: String, iconName: String = "cube", bandwidthLabel: String? = nil, uid: String? = nil, children: [DeviceNode]? = nil, bandwidthRatio: Double? = nil, dscActive: Bool = false, displayDetails: DisplayDetails? = nil, rawBandwidth: Double? = nil, peripheralDetails: PeripheralDetails? = nil) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.bandwidthLabel = bandwidthLabel
        self.uid = uid
        self.children = children
        self.bandwidthRatio = bandwidthRatio
        self.dscActive = dscActive
        self.displayDetails = displayDetails
        self.rawBandwidth = rawBandwidth
        self.peripheralDetails = peripheralDetails
    }
}
