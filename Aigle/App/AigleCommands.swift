import SwiftUI

/// Menu bar commands and their keyboard shortcuts.
struct AigleCommands: Commands {
    let controller: LibraryController
    let bus: CommandBus
    let setup: SetupModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Collection…") { bus.newCollection() }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!controller.isOpen)

            Button("Import Files…") { bus.showImportPicker() }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(!controller.isOpen)

            Button("Connect Folder…") { bus.connectFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!controller.isOpen)

            Divider()

            Button("Close Library") { controller.closeLibrary() }
                .disabled(!controller.isOpen)
        }

        CommandMenu("Item") {
            Button("Search Everything…") { bus.isSearchPresented = true }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(!controller.isOpen)

            Button("Tags…") { bus.isTagEditorPresented = true }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(controller.selectedItemIDs.isEmpty)

            Button(controller.selectedItems.allSatisfy(\.liked) ? "Unlike" : "Like") {
                controller.toggleLike(ids: controller.selectedItemIDs)
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(controller.selectedItemIDs.isEmpty)

            Divider()

            // Space is handled by the grid's own event monitor rather than a menu
            // shortcut, so it still works on hover and never steals the key from
            // a text field.
            Button("Quick Look") { bus.toggleQuickLook() }
                .disabled(!controller.isOpen)

            Button("Save Current Frame to Inbox") { bus.saveFrame() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(controller.detailItem?.kind != .video)

            Divider()

            Button("Reveal in Finder") { controller.revealInFinder(ids: controller.selectedItemIDs) }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(controller.selectedItemIDs.isEmpty)

            Button("Move to Trash") { controller.moveToTrash(ids: controller.selectedItemIDs) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(controller.selectedItemIDs.isEmpty)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { bus.zoomIn() }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(!controller.isOpen)
            Button("Zoom Out") { bus.zoomOut() }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(!controller.isOpen)
        }

        CommandGroup(replacing: .help) {
            Button("Setup Assistant") { setup.reopen() }
            Divider()
            Link("Aigle on GitHub", destination: URL(string: "https://github.com/")!)
        }
    }
}
