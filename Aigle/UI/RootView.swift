import SwiftUI

struct RootView: View {
    @Environment(LibraryController.self) private var controller
    @Environment(SetupModel.self) private var setup
    @Environment(AppSettings.self) private var settings

    /// Setup owns the window until it has been completed once and a library is
    /// actually open — a library that stops resolving (moved, unplugged drive,
    /// revoked permission) brings the assistant back on its own.
    private var showSetup: Bool { setup.isActive(libraryOpen: controller.isOpen) }

    var body: some View {
        Group {
            if showSetup {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .animation(
            settings.motionReduced ? .easeInOut(duration: 0.18) : .smooth(duration: 0.28),
            value: showSetup
        )
    }
}
