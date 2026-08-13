import SwiftUI

/// The app's spacing, radius and motion scale.
///
/// Every magic number that used to live inline belongs here instead: a view that
/// reaches for `14` or `.snappy(duration: 0.16)` directly is how a layout drifts
/// out of alignment one edit at a time.
public enum Metrics {
    /// 4-point scale. Nothing in the UI should use a value between these.
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20

    /// Small controls: chips, badges, fields.
    public static let radiusSmall: CGFloat = 6
    /// Cards, panels, floating chrome.
    public static let radiusLarge: CGFloat = 10

    /// Inset from the window edge to grid content.
    public static let gridInset: CGFloat = 16
    /// Width of the trailing count column in the sidebar, so digits line up
    /// across rows regardless of how many characters each count has.
    public static let sidebarCountWidth: CGFloat = 28
}

public enum Motion {
    /// The app's one spring. Hover, selection, panel transitions all share it so
    /// the whole window feels like a single mechanism.
    public static let standard: Animation = .smooth(duration: 0.25)
    /// For state that must feel immediate under the cursor.
    public static let quick: Animation = .smooth(duration: 0.16)

    /// Returns `nil` when the user asked for less motion, which disables the
    /// animation at the call site rather than merely shortening it.
    @MainActor
    public static func standard(_ settings: AppSettings) -> Animation? {
        settings.motionReduced ? nil : standard
    }

    @MainActor
    public static func quick(_ settings: AppSettings) -> Animation? {
        settings.motionReduced ? nil : quick
    }
}

extension ShapeStyle where Self == Color {
    /// Hairline separators and control borders.
    static var hairline: Color { Color(nsColor: .separatorColor) }
}

/// A shape used for every card-like surface, so radius and smoothing match.
public func cardShape(_ radius: CGFloat = Metrics.radiusLarge) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}

// MARK: - Shared sheet chrome

/// One layout for every small modal: rename, new collection, new subcollection.
///
/// These were three near-identical copies that had already drifted apart in
/// padding and field width; centralising them keeps them honest.
struct FormSheet<Content: View, Actions: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.l) {
            Text(title)
                .font(.headline)
            content
            HStack(spacing: Metrics.s) {
                Spacer()
                actions
            }
        }
        .padding(Metrics.xl)
        .frame(width: 320)
    }
}
