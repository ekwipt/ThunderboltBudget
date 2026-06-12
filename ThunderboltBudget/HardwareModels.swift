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
    }
}

struct ReceptacleTag: Codable {
    var current_speed_key: String?
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

    init(id: UUID = UUID(), name: String, iconName: String = "cube", bandwidthLabel: String? = nil, uid: String? = nil, children: [DeviceNode]? = nil, bandwidthRatio: Double? = nil, dscActive: Bool = false, displayDetails: DisplayDetails? = nil, rawBandwidth: Double? = nil) {
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
    }
}
