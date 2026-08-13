import CoreGraphics
import Foundation

// Lists on-screen windows without needing any TCC permission.
//
// This is deliberately NOT osascript/System Events: window geometry via
// CGWindowListCopyWindowInfo needs no Accessibility grant, so it still works on
// a machine where the agent has not been given (or has been denied) automation
// rights. Use it to find a window id before `screencapture -l <id>`.
//
//   swift winlist.swift            → every on-screen window
//   swift winlist.swift Aigle      → only windows owned by a process named Aigle
//
// Output is tab-separated: id, owner pid, owner name, w, h, x, y, title

let filter = CommandLine.arguments.dropFirst().first

guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else {
    FileHandle.standardError.write(Data("winlist: CGWindowListCopyWindowInfo returned nil\n".utf8))
    exit(1)
}

var found = 0
for window in raw {
    guard let id = window[kCGWindowNumber as String] as? Int,
          let owner = window[kCGWindowOwnerName as String] as? String,
          let pid = window[kCGWindowOwnerPID as String] as? Int,
          let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    else { continue }

    if let filter, owner.caseInsensitiveCompare(filter) != .orderedSame { continue }

    // Menu-bar extras, shadows and other chrome come back as slivers; they are
    // never what you want to screenshot.
    if bounds.width < 80 || bounds.height < 80 { continue }

    let title = (window[kCGWindowName as String] as? String) ?? ""
    print([
        String(id), String(pid), owner,
        String(Int(bounds.width)), String(Int(bounds.height)),
        String(Int(bounds.minX)), String(Int(bounds.minY)),
        title,
    ].joined(separator: "\t"))
    found += 1
}

if found == 0 {
    FileHandle.standardError.write(Data("winlist: no windows\((filter.map { " for \($0)" }) ?? "")\n".utf8))
    exit(2)
}
