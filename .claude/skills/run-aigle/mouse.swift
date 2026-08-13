import CoreGraphics
import Foundation

// Posts a real mouse event at a screen point.
//
// System Events' `click at {x, y}` does NOT work on this app's SwiftUI content:
// it dispatches through the accessibility layer, and SwiftUI's grid/canvas
// views have no AXPress action to receive it, so the click is silently
// swallowed. A synthesised CGEvent goes through the real event tap instead and
// behaves exactly like a human clicking.
//
//   swift mouse.swift 1123 353           → left click
//   swift mouse.swift 1123 353 double    → double click (opens the detail view)
//   swift mouse.swift 1123 353 cmd       → cmd-click (extends selection)
//   swift mouse.swift 1123 353 move      → hover only, no click

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: mouse.swift <x> <y> [double|cmd|shift|move]\n".utf8))
    exit(64)
}
let mode = args.count > 3 ? args[3] : "click"
let point = CGPoint(x: x, y: y)

var flags: CGEventFlags = []
switch mode {
case "cmd": flags = .maskCommand
case "shift": flags = .maskShift
default: break
}

func post(_ type: CGEventType, clickCount: Int64 = 1) {
    guard let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left
    ) else { return }
    event.flags = flags
    if clickCount > 1 { event.setIntegerValueField(.mouseEventClickState, value: clickCount) }
    event.post(tap: .cghidEventTap)
}

// Move first: SwiftUI hover state (and therefore some hit testing) keys off the
// pointer actually being over the view before the button goes down.
post(.mouseMoved)
usleep(120_000)

if mode == "move" {
    print("moved to \(Int(x)),\(Int(y))")
    exit(0)
}

post(.leftMouseDown)
usleep(40_000)
post(.leftMouseUp)

if mode == "double" {
    usleep(80_000)
    post(.leftMouseDown, clickCount: 2)
    usleep(40_000)
    post(.leftMouseUp, clickCount: 2)
}

print("\(mode) at \(Int(x)),\(Int(y))")
