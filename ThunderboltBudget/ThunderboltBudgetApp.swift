import SwiftUI
import AppKit

extension NSImage {
    // Generate a raw vector image that ignores SwiftUI's strict MenuBar constraints
    static var menuBarIcon: NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        let image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: nil)!
        let scaledImage = image.withSymbolConfiguration(config) ?? image
        scaledImage.isTemplate = true
        return scaledImage
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct ThunderboltBudgetApp: App {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }

        MenuBarExtra {
            MenuBarView()
                .preferredColorScheme(appearanceMode.colorScheme)
        } label: {
            Image(nsImage: NSImage.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
