import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "sparkles",
                title: "A calm home for what you collect",
                subtitle: "Images, videos and links, in one folder you own. Aigle keeps nothing of its own and uploads nothing anywhere."
            )

            VStack(alignment: .leading, spacing: 14) {
                Bullet(
                    symbol: "folder",
                    title: "Your library is a plain folder",
                    detail: "Readable without Aigle, and compatible with Eagle libraries as they are."
                )
                Bullet(
                    symbol: "lock.shield",
                    title: "Only the access you grant",
                    detail: "Aigle is sandboxed. It reaches exactly the folders you hand it, and this setup verifies each one."
                )
                Bullet(
                    symbol: "bolt",
                    title: "Built for big libraries",
                    detail: "Tested against 50,000 items — scrolling, zooming and search stay immediate."
                )
            }

            Spacer(minLength: 0)
        }
    }
}

private struct Bullet: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Library

struct LibraryStep: View {
    @Environment(LibraryController.self) private var controller
    @Environment(SetupModel.self) private var setup

    @State private var isCreating = false
    @State private var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "books.vertical",
                title: "Choose where your library lives",
                subtitle: "Internal disk, an external drive, Dropbox or iCloud Drive — Aigle writes a plain folder wherever you point it."
            )

            if controller.isOpen, let layout = controller.snapshot?.layout {
                OpenLibraryPanel(root: layout.root)
            } else {
                Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                    GridRow {
                        ChoiceCard(
                            symbol: "plus.rectangle.on.folder",
                            title: "Create a library",
                            subtitle: "Pick a folder and Aigle sets up a fresh library inside it."
                        ) { isCreating = true }

                        ChoiceCard(
                            symbol: "folder",
                            title: "Open a library",
                            subtitle: "Existing Aigle or Eagle libraries open as they are."
                        ) { isOpening = true }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = controller.loadError {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .animation(.smooth(duration: 0.25), value: controller.isOpen)
        .sheet(isPresented: $isCreating) {
            CreateLibrarySheet()
        }
        .fileImporter(
            isPresented: $isOpening,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            controller.clearLoadError()
            Task { await controller.openLibrary(at: url) }
        }
    }
}

private struct OpenLibraryPanel: View {
    @Environment(LibraryController.self) private var controller
    let root: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(root.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                    Text(root.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if let provider = SystemChecks.syncProvider(for: root) {
                Label("Stored in \(provider) — it follows you to your other Macs.", systemImage: "icloud")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                }
                Button("Choose a different library") {
                    controller.closeLibrary()
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct ChoiceCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(.quaternary.opacity(isHovering ? 0.5 : 0.28), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.separator.opacity(isHovering ? 0.9 : 0.5))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(settings.motionReduced ? nil : .snappy(duration: 0.16), value: isHovering)
    }
}

/// Creating a library needs the *parent* folder's security scope held across the
/// write, so the sheet keeps the picked URL and hands it to the controller.
private struct CreateLibrarySheet: View {
    @Environment(LibraryController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Aigle"
    @State private var parent: URL?
    @State private var isPickingFolder = false
    @State private var probe: SystemChecks.WriteProbe?

    private var targetPath: String? {
        guard let parent else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parent.appending(path: "\(trimmed).library").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a library")
                .font(.title2.weight(.semibold))

            LabeledContent("Name") {
                TextField("Library name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
            }

            LabeledContent("Location") {
                HStack(spacing: 8) {
                    Text(parent?.path ?? String(localized: "Not chosen yet"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(parent == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { isPickingFolder = true }
                }
                .frame(width: 250)
            }

            // The permission is verified the moment a folder is picked, so a
            // location Aigle can't write to is caught here and not after the
            // Create button has already failed.
            if let probe {
                switch probe {
                case .writable:
                    Label("Aigle can write here.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                case .notWritable(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let targetPath {
                Text(targetPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    guard let parent else { return }
                    controller.clearLoadError()
                    let libraryName = name
                    dismiss()
                    Task { await controller.createLibrary(named: libraryName, in: parent) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parent == nil || targetPath == nil)
            }
        }
        .padding(22)
        .frame(width: 480)
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            parent = url
            probe = SystemChecks.probeWritable(url)
        }
        .fileDialogDefaultDirectory(CoordinatedIO.iCloudDriveURL)
    }
}

// MARK: - Permissions

struct PermissionsStep: View {
    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(SetupModel.self) private var setup
    @Environment(ExtensionServer.self) private var server

    @State private var isChoosingLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                StepHeader(
                    symbol: "lock.shield",
                    title: "What Aigle can reach",
                    subtitle: "Each row below was just tested for real — writing a probe file, resolving a saved bookmark, binding the port. Nothing here is remembered from an earlier answer."
                )
                Spacer()
                Button {
                    Task { await setup.refresh(controller: controller, settings: settings, server: server) }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(setup.isRefreshing)
            }

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(setup.checks) { check in
                        CheckRow(
                            check: check,
                            fixTitle: fixTitle(for: check.id),
                            fix: fixAction(for: check.id)
                        )
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)

            if !setup.blockingFailures.isEmpty {
                Label(
                    "Aigle can't store anything until the required rows pass.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.top, 10)
            }
        }
        .fileImporter(
            isPresented: $isChoosingLibrary,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await controller.openLibrary(at: url) }
        }
    }

    private func fixTitle(for kind: SetupCheckKind) -> LocalizedStringKey? {
        switch kind {
        case .libraryOpen, .libraryWritable, .libraryReopens: "Choose…"
        case .librarySynced: nil
        case .quickAccess: "Add…"
        case .extensionPort: "Settings…"
        case .safariExtension: "Open Safari settings"
        }
    }

    private func fixAction(for kind: SetupCheckKind) -> (() -> Void)? {
        switch kind {
        case .libraryOpen, .libraryWritable, .libraryReopens:
            { isChoosingLibrary = true }
        case .librarySynced:
            nil
        case .quickAccess:
            { setup.go(to: .access) }
        case .extensionPort:
            { setup.go(to: .browser) }
        case .safariExtension:
            { SystemChecks.openSafariExtensionPreferences() }
        }
    }
}

// MARK: - Quick access

struct QuickAccessStep: View {
    @Environment(SetupModel.self) private var setup
    @State private var pickingFolder: QuickAccessFolder?
    @State private var isPickingOther = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "folder.badge.person.crop",
                title: "Folders you collect from",
                subtitle: "Optional. macOS only lets a sandboxed app into a folder you hand it in a panel, so granting them now means connecting a folder later is a single click. Drag-and-drop from anywhere works regardless."
            )

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(setup.quickAccess) { folder in
                        FolderRow(folder: folder) {
                            pickingFolder = folder
                        } revoke: {
                            setup.revokeQuickAccess(folder)
                        }
                    }
                }
            }

            Button {
                isPickingOther = true
            } label: {
                Label("Add another folder…", systemImage: "plus")
            }
            .controlSize(.small)
            .padding(.top, 10)
        }
        .fileImporter(
            isPresented: Binding(
                get: { pickingFolder != nil },
                set: { if !$0 { pickingFolder = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            defer { pickingFolder = nil }
            guard case .success(let urls) = result, let url = urls.first else { return }
            setup.grantQuickAccess(to: url)
        }
        .fileDialogDefaultDirectory(pickingFolder?.url)
        .fileImporter(
            isPresented: $isPickingOther,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            setup.grantQuickAccess(to: url)
        }
    }
}

private struct FolderRow: View {
    let folder: QuickAccessFolder
    let grant: () -> Void
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.symbol)
                .font(.system(size: 14))
                .foregroundStyle(folder.isGranted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).font(.system(size: 13, weight: .medium))
                Text(folder.url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if folder.isGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Revoke", action: revoke)
                        .controlSize(.small)
                }
            } else {
                Button("Grant access…", action: grant)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.smooth(duration: 0.25), value: folder.isGranted)
    }
}

// MARK: - Browsers

struct BrowserStep: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SetupModel.self) private var setup

    var body: some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "safari",
                title: "Save from the web",
                subtitle: "Right-click any image, video or page and send it straight to a collection."
            )

            ScrollView {
                VStack(spacing: 10) {
                    if let safari = setup.check(.safariExtension) {
                        VStack(alignment: .leading, spacing: 10) {
                            CheckRow(
                                check: safari,
                                fixTitle: "Open Safari settings",
                                fix: { SystemChecks.openSafariExtensionPreferences() }
                            )
                            Text("The Safari extension ships inside Aigle — there's nothing to download. Safari only lists it once Aigle has been launched from your Applications folder.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Chrome bridge", isOn: $settings.extensionServerEnabled)
                            .font(.system(size: 13, weight: .medium))

                        Text("Runs a listener bound to 127.0.0.1 only, so nothing outside this Mac can reach it. The Chrome extension authenticates with the token below.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if settings.extensionServerEnabled {
                            if let port = setup.check(.extensionPort) {
                                CheckRow(check: port)
                            }

                            HStack(spacing: 8) {
                                Text(settings.extensionToken)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(settings.extensionToken, forType: .string)
                                }
                                .controlSize(.small)
                                if let folder = Bundle.main.url(forResource: "extension", withExtension: nil) {
                                    Button("Reveal extension…") {
                                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .animation(.smooth(duration: 0.25), value: settings.extensionServerEnabled)
                }
            }
        }
    }
}

// MARK: - Ready

struct ReadyStep: View {
    @Environment(SetupModel.self) private var setup
    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings

    private var outstanding: [SetupCheck] {
        setup.checks.filter { !$0.status.isPass && $0.weight != .optional }
    }

    var body: some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "checkmark.seal",
                title: "You're set up",
                subtitle: "Drop anything onto the window to start collecting. You can reopen this assistant any time from Help → Setup Assistant."
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(String(setup.passedCount)) of \(String(setup.checks.count)) checks passing")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }

                if !outstanding.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(outstanding) { check in
                            HStack(alignment: .top, spacing: 8) {
                                StatusBadge(status: check.status)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(check.title).font(.system(size: 12, weight: .medium))
                                    if let detail = check.status.detail {
                                        Text(detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        Button("Review them") { setup.go(to: .permissions) }
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }

                Toggle("Keep the menu bar icon, so you can drop things in with the window closed", isOn: $settings.showMenuBarIcon)
                    .font(.system(size: 12))

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text("Worth knowing")
                        .font(.system(size: 12, weight: .semibold))
                    ShortcutLine(keys: "Space", detail: "Quick Look whatever the pointer is over")
                    ShortcutLine(keys: "⌘K", detail: "Search the library and every connected folder")
                    ShortcutLine(keys: "⌘T", detail: "Tag the selection from anywhere")
                    ShortcutLine(keys: "⌘-scroll", detail: "Zoom the grid; pinch works too")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Spacer(minLength: 0)
        }
    }
}

private struct ShortcutLine: View {
    let keys: String
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
