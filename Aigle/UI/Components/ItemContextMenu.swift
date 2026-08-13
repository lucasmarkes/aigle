import AppKit
import SwiftUI

/// Right-click actions shared by the grid and the detail view.
struct ItemContextMenu: View {
    let item: Item

    @Environment(LibraryController.self) private var controller
    @Environment(CommandBus.self) private var bus

    private var targets: Set<String> {
        controller.selectedItemIDs.contains(item.id) ? controller.selectedItemIDs : [item.id]
    }

    private var isTrash: Bool {
        if case .smart(.trash) = controller.selection { return true }
        return false
    }

    private var isConnected: Bool { item.connectedFolderID != nil }

    var body: some View {
        Button("Open") { controller.openDetail(item.id) }
        Button("Open in Default App") { controller.openExternally(ids: targets) }
        Button("Reveal in Finder") { controller.revealInFinder(ids: targets) }

        Divider()

        if !isConnected {
            Button(item.liked ? "Unlike" : "Like") { controller.toggleLike(ids: targets) }
            Button("Rename…") { controller.renamingItemID = item.id }
                .disabled(targets.count != 1)
            Button("Tags…") { bus.isTagEditorPresented = true }

            Menu("Add to Collection") {
                ForEach(controller.collections.flattened) { collection in
                    Button(collection.name) { controller.addToCollection(collection.id, ids: targets) }
                }
                if controller.collections.isEmpty {
                    Text("No collections yet")
                }
            }

            if let collectionID = controller.selection.collectionID {
                Button("Remove from Collection") {
                    controller.removeFromCollection(collectionID, ids: targets)
                }
            }
        }

        Divider()

        Button("Copy") { copyToPasteboard() }

        if !isConnected {
            if isTrash {
                Button("Put Back") { controller.restore(ids: targets) }
                Button("Delete Permanently", role: .destructive) {
                    controller.deletePermanently(ids: targets)
                }
            } else {
                Button("Move to Trash", role: .destructive) { controller.moveToTrash(ids: targets) }
            }
        }
    }

    private func copyToPasteboard() {
        let urls = targets.compactMap { controller.item($0) }.compactMap(controller.fileURL(for:))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if urls.isEmpty {
            pasteboard.setString(item.url, forType: .string)
        } else {
            pasteboard.writeObjects(urls as [NSURL])
        }
    }
}
