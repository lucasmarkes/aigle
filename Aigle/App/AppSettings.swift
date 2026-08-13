import AppKit
import Observation
import SwiftUI

public enum AppearanceMode: String, CaseIterable, Sendable {
    case system, light, dark

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum SelectionTint: String, CaseIterable, Sendable {
    case blue, grey, primary, orange

    public var color: Color {
        switch self {
        case .blue: .accentColor
        case .grey: Color.secondary
        case .primary: Color.primary
        case .orange: Color.orange
        }
    }

    public var title: LocalizedStringKey {
        switch self {
        case .blue: "Blue"
        case .grey: "Grey"
        case .primary: "Primary"
        case .orange: "Orange"
        }
    }
}

public enum ThumbnailFit: String, CaseIterable, Sendable {
    case fit, fill

    public var title: LocalizedStringKey {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        }
    }
}

public enum GridBackground: String, CaseIterable, Sendable {
    case system, custom

    public var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .custom: "Custom"
        }
    }
}

/// Every user-facing preference, in one observable place so Settings changes
/// apply live everywhere without a restart.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // Appearance
    public var appearance: AppearanceMode { didSet { write(appearance.rawValue, "appearance") } }
    public var selectionTint: SelectionTint { didSet { write(selectionTint.rawValue, "selectionTint") } }
    public var gridBackground: GridBackground { didSet { write(gridBackground.rawValue, "gridBackground") } }
    public var customBackgroundHex: String { didSet { write(customBackgroundHex, "customBackgroundHex") } }

    // Grid
    public var gridSpacing: Double { didSet { write(gridSpacing, "gridSpacing") } }
    public var cornerRadius: Double { didSet { write(cornerRadius, "cornerRadius") } }
    public var thumbnailFit: ThumbnailFit { didSet { write(thumbnailFit.rawValue, "thumbnailFit") } }
    public var defaultZoom: Double { didSet { write(defaultZoom, "defaultZoom") } }
    public var showLikeBadges: Bool { didSet { write(showLikeBadges, "showLikeBadges") } }
    public var showFileNames: Bool { didSet { write(showFileNames, "showFileNames") } }
    public var autoplayInGrid: Bool { didSet { write(autoplayInGrid, "autoplayInGrid") } }

    // Behaviour
    public var virtualCopiesEnabled: Bool { didSet { write(virtualCopiesEnabled, "virtualCopiesEnabled") } }
    public var showMenuBarIcon: Bool { didSet { write(showMenuBarIcon, "showMenuBarIcon") } }
    public var reduceMotion: Bool { didSet { write(reduceMotion, "reduceMotion") } }
    public var confirmBeforeDelete: Bool { didSet { write(confirmBeforeDelete, "confirmBeforeDelete") } }

    // Extension server
    public var extensionServerEnabled: Bool { didSet { write(extensionServerEnabled, "extensionServerEnabled") } }
    public var extensionPort: Int { didSet { write(extensionPort, "extensionPort") } }
    public var extensionToken: String { didSet { write(extensionToken, "extensionToken") } }

    // Last opened library (path is informational; access comes from the bookmark)
    public var lastLibraryPath: String { didSet { write(lastLibraryPath, "lastLibraryPath") } }

    private init() {
        func string(_ key: String, _ fallback: String) -> String {
            UserDefaults.standard.string(forKey: "aigle." + key) ?? fallback
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            UserDefaults.standard.object(forKey: "aigle." + key) as? Double ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: "aigle." + key) as? Bool ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            UserDefaults.standard.object(forKey: "aigle." + key) as? Int ?? fallback
        }

        appearance = AppearanceMode(rawValue: string("appearance", "system")) ?? .system
        selectionTint = SelectionTint(rawValue: string("selectionTint", "blue")) ?? .blue
        gridBackground = GridBackground(rawValue: string("gridBackground", "system")) ?? .system
        customBackgroundHex = string("customBackgroundHex", "#1C1C1E")
        gridSpacing = double("gridSpacing", 8)
        cornerRadius = double("cornerRadius", 6)
        thumbnailFit = ThumbnailFit(rawValue: string("thumbnailFit", "fit")) ?? .fit
        defaultZoom = double("defaultZoom", 220)
        showLikeBadges = bool("showLikeBadges", true)
        showFileNames = bool("showFileNames", false)
        autoplayInGrid = bool("autoplayInGrid", false)
        virtualCopiesEnabled = bool("virtualCopiesEnabled", true)
        showMenuBarIcon = bool("showMenuBarIcon", true)
        reduceMotion = bool("reduceMotion", false)
        confirmBeforeDelete = bool("confirmBeforeDelete", true)
        extensionServerEnabled = bool("extensionServerEnabled", false)
        extensionPort = int("extensionPort", 41417)
        extensionToken = string("extensionToken", "")
        lastLibraryPath = string("lastLibraryPath", "")

        if extensionToken.isEmpty {
            extensionToken = Self.freshToken()
        }
    }

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "aigle." + key)
    }

    public static func freshToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func regenerateToken() { extensionToken = Self.freshToken() }

    /// The system's Reduce Motion switch always wins; the in-app toggle can only
    /// add to it, never override it.
    public var motionReduced: Bool {
        reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public var resolvedBackground: Color? {
        gridBackground == .custom ? Color(hex: customBackgroundHex) : nil
    }
}

extension Color {
    /// `#RRGGBB` / `#AARRGGBB` parsing for the custom grid background.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard let value = UInt64(text, radix: 16) else { return nil }
        switch text.count {
        case 6:
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: 1
            )
        case 8:
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: Double((value >> 24) & 0xFF) / 255
            )
        default:
            return nil
        }
    }

    public var hexString: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
