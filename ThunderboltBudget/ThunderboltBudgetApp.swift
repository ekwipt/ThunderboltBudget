import SwiftUI
import AppKit
import Combine

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

    // nil here means "defer to the live system value" -- resolved by SystemAppearanceObserver,
    // never passed straight to .preferredColorScheme(). Passing nil there directly is what causes
    // stale colors: resetting a window's appearance back to "follow system" after it was set
    // explicitly doesn't reliably repropagate through every AppKit-bridged color/material.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// Tracks the actual system appearance so "System" mode can be resolved to a concrete
// .light/.dark value instead of ever passing nil to .preferredColorScheme.
final class SystemAppearanceObserver: ObservableObject {
    @Published var colorScheme: ColorScheme = SystemAppearanceObserver.currentSystemColorScheme()

    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.colorScheme = SystemAppearanceObserver.currentSystemColorScheme()
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private static func currentSystemColorScheme() -> ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

@main
struct ThunderboltBudgetApp: App {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @StateObject private var systemAppearance = SystemAppearanceObserver()

    private var effectiveColorScheme: ColorScheme {
        appearanceMode.colorScheme ?? systemAppearance.colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(effectiveColorScheme)
                .preferredColorScheme(effectiveColorScheme)
        }

        MenuBarExtra {
            MenuBarView()
                .id(effectiveColorScheme)
                .preferredColorScheme(effectiveColorScheme)
        } label: {
            Image(nsImage: NSImage.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        // Contributes the standard "Settings…" (⌘,) item under the app menu's About section.
        Settings {
            SettingsView()
                .id(effectiveColorScheme)
                .preferredColorScheme(effectiveColorScheme)
        }
    }
}
