import Observation
import SwiftUI

/// One-way signals from menu commands / key shortcuts to whichever view owns the
/// behaviour. Views observe the counters rather than the app storing UI state.
@MainActor
@Observable
public final class CommandBus {
    public var isSearchPresented = false
    public var isTagEditorPresented = false
    public var zoomInTicks = 0
    public var zoomOutTicks = 0
    public var saveFrameTicks = 0
    public var toggleQuickLookTicks = 0
    public var newCollectionTicks = 0
    public var importPickerTicks = 0
    public var connectFolderTicks = 0

    public init() {}

    public func zoomIn() { zoomInTicks &+= 1 }
    public func zoomOut() { zoomOutTicks &+= 1 }
    public func saveFrame() { saveFrameTicks &+= 1 }
    public func toggleQuickLook() { toggleQuickLookTicks &+= 1 }
    public func newCollection() { newCollectionTicks &+= 1 }
    public func showImportPicker() { importPickerTicks &+= 1 }
    public func connectFolder() { connectFolderTicks &+= 1 }
}
