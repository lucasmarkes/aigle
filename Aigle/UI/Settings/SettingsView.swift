import AppKit
import SwiftUI

/// ⌘, — everything customisable, applied live.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Appearance", systemImage: "paintbrush") {
                AppearanceSettings()
            }
            Tab("Grid", systemImage: "square.grid.2x2") {
                GridSettings()
            }
            Tab("Extensions", systemImage: "puzzlepiece.extension") {
                ExtensionSettings()
            }
            Tab("Setup", systemImage: "lock.shield") {
                SetupSettings()
            }
        }
        .frame(width: 520, height: 430)
    }
}

/// The same live probes the assistant runs, kept available for later — this is
/// where you look when saving suddenly stops working because a drive was
/// unplugged or a permission was revoked in System Settings.
private struct SetupSettings: View {
    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(SetupModel.self) private var setup
    @Environment(ExtensionServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Checked live, every time this opens.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(setup.isRefreshing)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(setup.checks) { check in
                        CheckRow(check: check)
                    }
                }
            }

            Button("Open Setup Assistant…") { setup.reopen() }
                .controlSize(.small)
        }
        .padding(18)
        .task { await refresh() }
    }

    private func refresh() async {
        await setup.refresh(controller: controller, settings: settings, server: server)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryController.self) private var controller

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Library") {
                LabeledContent("Location") {
                    Text(controller.snapshot?.layout.root.path ?? String(localized: "No library open"))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Reveal in Finder") {
                    guard let root = controller.snapshot?.layout.root else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                }
                .disabled(!controller.isOpen)
            }

            Section("Behaviour") {
                Toggle("Create virtual copies instead of duplicates", isOn: $settings.virtualCopiesEnabled)
                    .help("Re-adding a file already in the library adds a second entry pointing at the same bytes.")
                Toggle("Confirm before emptying the trash", isOn: $settings.confirmBeforeDelete)
                Toggle("Show the menu bar icon", isOn: $settings.showMenuBarIcon)
                    .help("Drop files or links on it to add them to your Inbox.")
            }

            Section("Accessibility") {
                Toggle("Reduce motion", isOn: $settings.reduceMotion)
                    .help("Crossfades instead of zooming geometry. The system setting is respected too.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Selection colour", selection: $settings.selectionTint) {
                    ForEach(SelectionTint.allCases, id: \.self) { tint in
                        Label {
                            Text(tint.title)
                        } icon: {
                            Circle().fill(tint.color).frame(width: 10, height: 10)
                        }
                        .tag(tint)
                    }
                }
            }

            Section("Grid background") {
                Picker("Background", selection: $settings.gridBackground) {
                    ForEach(GridBackground.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if settings.gridBackground == .custom {
                    ColorPicker("Colour", selection: Binding(
                        get: { Color(hex: settings.customBackgroundHex) ?? .black },
                        set: { settings.customBackgroundHex = $0.hexString }
                    ))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GridSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Layout") {
                LabeledContent("Spacing") {
                    HStack {
                        Slider(value: $settings.gridSpacing, in: 0...32, step: 1)
                        Text("\(Int(settings.gridSpacing)) pt")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Corner radius") {
                    HStack {
                        Slider(value: $settings.cornerRadius, in: 0...24, step: 1)
                        Text("\(Int(settings.cornerRadius)) pt")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Default zoom") {
                    HStack {
                        Slider(value: $settings.defaultZoom, in: 80...720, step: 10)
                        Text("\(Int(settings.defaultZoom)) pt")
                            .font(.caption.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Picker("Thumbnails", selection: $settings.thumbnailFit) {
                    ForEach(ThumbnailFit.allCases, id: \.self) { fit in
                        Text(fit.title).tag(fit)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Contents") {
                Toggle("Show like badges", isOn: $settings.showLikeBadges)
                Toggle("Show file names", isOn: $settings.showFileNames)
                Toggle("Play videos and GIFs in the grid", isOn: $settings.autoplayInGrid)
                    .help("Only visible cells animate.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtensionSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ExtensionServer.self) private var server

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Safari") {
                Text("Aigle ships a Safari extension inside the app — no separate download.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Safari Extension Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Safari.extensions")!)
                }
            }

            Section("Chrome & other browsers") {
                Toggle("Allow the browser extension to connect", isOn: $settings.extensionServerEnabled)
                    .help("Runs a local server on 127.0.0.1 only. Nothing is exposed to the network.")

                LabeledContent("Port") {
                    TextField("Port", value: $settings.extensionPort, format: .number.grouping(.never))
                        .frame(width: 90)
                        .disabled(settings.extensionServerEnabled)
                }

                LabeledContent("Token") {
                    HStack {
                        Text(settings.extensionToken)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(settings.extensionToken, forType: .string)
                        }
                        Button("New") { settings.regenerateToken() }
                    }
                }

                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch server.state {
        case .stopped: String(localized: "Off")
        case .starting: String(localized: "Starting…")
        case .running(let port): String(localized: "Listening on 127.0.0.1:\(String(port))")
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch server.state {
        case .running: .green
        case .failed: .red
        default: .secondary
        }
    }
}
