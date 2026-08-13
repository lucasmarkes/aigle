import SwiftUI

/// The setup assistant. It's the whole window until a library is open and the
/// user has been through once; after that it lives on in Settings → Setup and
/// under Help → Setup Assistant.
///
/// Progress is persisted, so quitting halfway through and coming back lands on
/// the same step — and every permission row is a live probe, re-run whenever the
/// window comes forward, because the user may have just changed something in
/// System Settings or Safari.
struct OnboardingView: View {
    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(SetupModel.self) private var setup
    @Environment(ExtensionServer.self) private var server

    private var motionReduced: Bool { settings.motionReduced }

    var body: some View {
        HStack(spacing: 0) {
            StageRail()
                .frame(width: 208)

            Divider()

            VStack(spacing: 0) {
                stageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 40)
                    .padding(.top, 40)
                    .padding(.bottom, 20)

                footer
            }
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .task(id: setup.stage) { await refresh() }
        // Permissions change outside the app. Re-probe whenever Aigle comes back
        // to the front rather than trusting what we saw a minute ago.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        ZStack {
            switch setup.stage {
            case .welcome: WelcomeStep()
            case .library: LibraryStep()
            case .permissions: PermissionsStep()
            case .access: QuickAccessStep()
            case .browser: BrowserStep()
            case .ready: ReadyStep()
            }
        }
        .id(setup.stage)
        .transition(stageTransition)
        .animation(motionReduced ? .easeInOut(duration: 0.18) : .smooth(duration: 0.32), value: setup.stage)
    }

    private var stageTransition: AnyTransition {
        guard !motionReduced else { return .opacity }
        let travel: CGFloat = setup.direction >= 0 ? 26 : -26
        return .asymmetric(
            insertion: .offset(x: travel).combined(with: .opacity),
            removal: .offset(x: -travel).combined(with: .opacity)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if setup.canRetreat {
                Button("Back") { setup.retreat() }
                    .keyboardShortcut("[", modifiers: .command)
            }

            Spacer()

            if setup.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }

            // Skipping only makes sense once a library exists — everything the
            // remaining steps offer is optional, but the library isn't.
            if setup.stage != .ready, setup.stage != .welcome, controller.isOpen {
                Button("Skip the rest") { setup.go(to: .ready) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            primaryButton
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 18)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.smooth(duration: 0.2), value: setup.isRefreshing)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if setup.stage == .ready {
            Button(controller.isOpen ? "Start using Aigle" : "Choose a library first") {
                setup.finish()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!controller.isOpen)
        } else {
            Button(setup.stage == .welcome ? "Get started" : "Continue") {
                setup.advance()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!setup.canAdvance(libraryOpen: controller.isOpen))
        }
    }

    private func refresh() async {
        setup.enforceLibraryGate(libraryOpen: controller.isOpen)
        await setup.refresh(controller: controller, settings: settings, server: server)
    }
}

// MARK: - Step rail

private struct StageRail: View {
    @Environment(SetupModel.self) private var setup
    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings

    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.tint)
                Text("Aigle")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .padding(.top, 26)
            .padding(.bottom, 22)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(setup.stages) { stage in
                    row(for: stage)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)

            Text("Setup remembers where you left off.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.25))
    }

    private func row(for stage: SetupStage) -> some View {
        let isCurrent = setup.stage == stage
        let isDone = setup.hasSeen(stage) && !isCurrent

        return Button {
            setup.go(to: stage)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: isDone ? "checkmark.circle.fill" : stage.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(isCurrent ? .primary : .secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 18)

                Text(stage.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.quaternary)
                        .matchedGeometryEffect(id: "stagePill", in: pill)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The library step is a gate: nothing past it means anything without one.
        .disabled(!controller.isOpen && stageIndex(stage) > stageIndex(.library))
        .animation(
            settings.motionReduced ? .easeInOut(duration: 0.15) : .snappy(duration: 0.28),
            value: setup.stage
        )
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private func stageIndex(_ stage: SetupStage) -> Int {
        setup.stages.firstIndex(of: stage) ?? 0
    }
}
