import AppKit
import Foundation

// Builds an Eagle-format library full of generated artwork, so the UI can be
// driven against real content without shipping binary fixtures in the repo.
//
//   swift make-demo-library.swift ~/Aigle\ Demo.library
//
// 24 items across 8 aspect ratios (so the justified grid has something to
// justify), nested collections, a tag vocabulary, some liked items, and a few
// items deliberately left folder-less so the Inbox is not empty.

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~/Aigle Demo.library").expandingTildeInPath)

let fm = FileManager.default
let images = root.appending(path: "images")
try? fm.removeItem(at: root)
try fm.createDirectory(at: images, withIntermediateDirectories: true)
try fm.createDirectory(at: root.appending(path: ".aigle/thumbs"), withIntermediateDirectories: true)

let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
func newID() -> String { String((0..<13).map { _ in alphabet.randomElement()! }) }
let now = Int(Date().timeIntervalSince1970 * 1000)

// MARK: - Artwork

func makeImage(width: Int, height: Int, hue: CGFloat, style: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let w = CGFloat(width), h = CGFloat(height)

    let c1 = NSColor(calibratedHue: hue, saturation: 0.62, brightness: 0.95, alpha: 1)
    let c2 = NSColor(calibratedHue: fmod(hue + 0.16, 1.0), saturation: 0.78, brightness: 0.55, alpha: 1)
    NSGradient(starting: c1, ending: c2)!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 55)

    ctx.setLineWidth(max(1.5, w / 220))
    switch style % 4 {
    case 0:  // concentric rings
        for i in 0..<14 {
            let r = min(w, h) * (0.08 + CGFloat(i) * 0.055)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.strokeEllipse(in: CGRect(x: w/2 - r, y: h/2 - r, width: r*2, height: r*2))
        }
    case 1:  // diagonal stripes
        ctx.setFillColor(NSColor(white: 1, alpha: 0.12).cgColor)
        var x = -h
        while x < w {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x + h, y: h))
            ctx.addLine(to: CGPoint(x: x + h + w/16, y: h))
            ctx.addLine(to: CGPoint(x: x + w/16, y: 0))
            ctx.closePath()
            ctx.fillPath()
            x += w / 7
        }
    case 2:  // dot grid
        ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
        let step = min(w, h) / 9
        var y = step / 2
        while y < h {
            var x = step / 2
            while x < w {
                let r = step * 0.16
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r*2, height: r*2))
                x += step
            }
            y += step
        }
    default:  // stacked bars
        ctx.setFillColor(NSColor(white: 0, alpha: 0.14).cgColor)
        var y = h * 0.1
        var k = 0
        while y < h {
            let bw = w * (0.3 + CGFloat((k * 37) % 60) / 100)
            ctx.fill(CGRect(x: w * 0.08, y: y, width: bw, height: h / 22))
            y += h / 9
            k += 1
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

@discardableResult
func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws -> Int {
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: url)
    return data.count
}

func thumbnail(_ rep: NSBitmapImageRep, maxEdge: CGFloat = 400) -> NSBitmapImageRep {
    let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
    let scale = min(1, maxEdge / max(w, h))
    let tw = Int(w * scale), th = Int(h * scale)
    let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

// MARK: - Collections

struct Coll { let id = newID(); let name: String; var children: [Coll] = [] }
let gradients = Coll(name: "Gradients")
let patterns = Coll(name: "Patterns")
let wide = Coll(name: "Wide")
let collections = [Coll(name: "Inspiration", children: [gradients, patterns]), wide]

func collJSON(_ c: Coll) -> [String: Any] {
    [
        "id": c.id, "name": c.name, "description": "",
        "children": c.children.map(collJSON),
        "modificationTime": now, "tags": [], "iconColor": "", "icon": "",
    ]
}

// MARK: - Items

let names = [
    "Sunrise Ridge", "Cobalt Drift", "Paper Bloom", "Neon Alley", "Soft Static",
    "Harbour Light", "Fold Study", "Warm Signal", "Glass Curve", "Late Orbit",
    "Quiet Field", "Copper Mesh", "Tidal Grid", "Amber Shift", "Slate Bloom",
    "Violet Pass", "Ember Lines", "Frost Panel", "Dune Echo", "Mint Circuit",
    "Rust Halo", "Ivory Wave", "Deep Current", "Pale Anchor",
]
let tagPool = ["gradient", "abstract", "poster", "texture", "cool", "warm", "geometry", "reference", "wallpaper"]
let sizes: [(Int, Int)] = [
    (1600, 1000), (1200, 1600), (1400, 1400), (1920, 820), (1000, 1500),
    (1500, 1125), (900, 1600), (1800, 1200),
]

for (i, name) in names.enumerated() {
    let id = newID()
    let dir = images.appending(path: "\(id).info")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    let (w, h) = sizes[i % sizes.count]
    let rep = makeImage(width: w, height: h, hue: CGFloat(i) / CGFloat(names.count), style: i)
    let bytes = try writePNG(rep, to: dir.appending(path: "\(name).png"))
    try writePNG(thumbnail(rep), to: dir.appending(path: "\(name)_thumbnail.png"))

    let tags = Array(Set([tagPool[i % tagPool.count], tagPool[(i * 3 + 1) % tagPool.count]])).sorted()

    var folders: [String] = []
    if Double(w) > Double(h) * 1.5 { folders.append(wide.id) }
    else if i % 3 == 0 { folders.append(gradients.id) }
    else if i % 3 == 1 { folders.append(patterns.id) }
    // every third item stays in the Inbox (no folder)

    let stamp = now - (names.count - i) * 86_400_000
    let meta: [String: Any] = [
        "id": id, "name": name, "size": bytes,
        "btime": stamp, "mtime": stamp, "modificationTime": stamp,
        "ext": "png", "tags": tags, "folders": folders,
        "isDeleted": false, "url": "", "annotation": "",
        "height": h, "width": w, "noThumbnail": false, "star": 0,
        "palettes": [],
        "aigle": ["liked": i % 5 == 0],
    ]
    try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        .write(to: dir.appending(path: "metadata.json"))
}

// MARK: - Library files

let libraryMeta: [String: Any] = [
    "id": newID(),
    "folders": collections.map(collJSON),
    "smartFolders": [], "quickAccess": [], "tagsGroups": [],
    "modificationTime": now,
    "applicationVersion": "4.0.0",
]
try JSONSerialization.data(withJSONObject: libraryMeta, options: [.sortedKeys])
    .write(to: root.appending(path: "metadata.json"))
try JSONSerialization.data(withJSONObject: [
    "historyTags": tagPool,
    "starredTags": ["gradient", "poster"],
    "recentTags": Array(tagPool.prefix(4)),
], options: [.sortedKeys]).write(to: root.appending(path: "tags.json"))
try Data("{}".utf8).write(to: root.appending(path: "mtime.json"))

print("\(root.path): \(names.count) items, \(collections.flatMap { [$0] + $0.children }.count) collections")
