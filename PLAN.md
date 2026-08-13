# Aigle — Plan

Native SwiftUI macOS app: an open-source alternative to Eagle (en.eagle.cool), modeled closely on Atlas (atlasformac.com) **including Atlas v1.1 features**. Everything on the Atlas landing page + v1.1 changelog **except** the iOS companion app and MCP support.

## Environment (verified)

- Xcode 26.6 (build 17F113), macOS 26.5.1, macOS SDK 26.5, Swift 6.3
- **Target macOS 26.0+.** Do NOT use SDK-27 APIs (the `swiftui-whats-new-27` skill documents 2027 releases — `@State` macro, `reorderable()`, `swipeActions` outside List, etc. are NOT available here; `@State` is still a property wrapper on this SDK).
- Project generation: `xcodegen` (installed at /opt/homebrew/bin/xcodegen) with a checked-in `project.yml`. Regenerate with `xcodegen generate`, build with `xcodebuild -project Aigle.xcodeproj -scheme Aigle build`.
- Consult the installed skills while coding: `swiftui-specialist` (idiomatic SwiftUI — read its references before writing views), `audit-xcode-security-settings` (near the end), and the `ui-skills` plugin's motion/polish principles (they're web-authored but the taste transfers: restraint, easing, spatial consistency, reduced motion).

## Product decisions

1. **Library format is Eagle-compatible on disk.** A library is a folder `<Name>.library/` containing:
   - `metadata.json` — library-level: collections ("folders" in Eagle terms) tree with ids, names, order, nesting; app version.
   - `images/<itemID>.info/` — one folder per item: `metadata.json` (id, name, ext, tags, folders[], size, width/height, url, annotation, mtime, isDeleted flag for trash, star/like state) + the original file + `<name>_thumbnail.png`.
   - `tags.json`, `mtime.json` — as Eagle writes them.
   Adopting this format makes "Bring your Eagle library" nearly free: **opening an existing Eagle `.library` folder just works** (import = open/adopt, plus a read-only validation pass). Verify exact field names against a real Eagle library structure — create a tiny fixture library from the documented format and write round-trip tests. Where Eagle's schema is ambiguous, prefer whatever Eagle actually writes; our own extra fields (likes, custom order, virtual copies) go in a namespaced `aigle` sub-object so Eagle can still open the library.
2. **Local-first, store anywhere.** The library folder can live on internal disk, external drive, Dropbox, or iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/...`). App Sandbox ON with `com.apple.security.files.user-selected.read-write`; persist access via security-scoped bookmarks. All reads/writes through `NSFileCoordinator` (safe for iCloud/Dropbox); handle undownloaded iCloud items (`NSMetadataQuery`/URL resource `ubiquitousItemDownloadingStatus`) by showing a placeholder and triggering download on demand. First-run flow: "Create library" (default suggestion: iCloud Drive/Aigle.library) or "Open existing" (accepts Eagle libraries).
3. **Connected folders are first-class** — reference files in place, no copying. Store a security-scoped bookmark + watch with FSEvents; own sidebar section. **Remember every folder's items in a persisted index with previews prepared in the background**, so browsing is as fast as the library and collections open instantly on launch (no grey placeholders). Thumbnail cache keyed by path+mtime.
4. **Collections**: nested tree, drag items in, drag to reorder collections, drag collection into collection, **sort collections alphabetically** (menu action). Sidebar counts. Special smart sections: All, Inbox (unfiled items), **Likes**, Trash (soft delete with restore + "Empty Trash" confirm). Folders (connected) get their own sidebar section.
5. **Likes**: ⌥-click a thumbnail to quick-like straight from the grid; like button in inspector/detail. **Like badges on thumbnails** (heart corner badge), hide-able in Settings. Likes smart section in sidebar.
6. **Sorting**: sort menu per view — date added / date created, newest or oldest, name, and **Custom order** (drag items into any order you like; persisted per collection).
7. **Virtual copies**: re-adding a file that's already in the library creates a virtual copy (second item referencing the same blob) instead of storing it twice — no "already in your library" prompt. Toggle in Settings → General.
8. **Search (⌘K)**: command-palette-style search over the whole library — type a name, hit return to open the item. **Reaches files in connected folders too.** Searches names and tags; fuzzy prefix matching; keyboard-first (arrows + return).
9. **Tags**: tag any item from the inspector **or press ⌘T anywhere** (popover tag editor on the selection, works with multi-select). Tag autocomplete from `tags.json`.
10. **Links**: paste or drop a URL anywhere → creates a link item (fetch page title, favicon, best og:image as the thumbnail). Rendered in the grid like any item; double-click opens in browser.
11. **Menu bar pin**: `MenuBarExtra` whose icon is a drop target — drop files/images/URLs on it → lands in Inbox (works while main window is closed; menu extra optional in settings).
12. **Browser extensions — two:**
    - **Safari extension, built right into the app** — a Safari Web Extension target embedded in Aigle.app, no separate install, flip it on in Settings (deep-link to Safari extension prefs). Context menu "Save to Aigle" on images/videos/pages; talks to the app via the native messaging handler.
    - **Chrome extension** (`extension/` in repo, MV3): context-menu save → `POST http://127.0.0.1:41417/save` (JSON: url, pageUrl, type). The app runs a localhost-only `NWListener` HTTP server (sandbox `com.apple.security.network.server`), off by default, toggle in Settings; random token generated by the app shown in Settings, extension options page stores it.
13. **Formats**: images (png/jpg/gif/webp/heic/tiff), **full SVG + PDF support** (render real thumbnails + full detail view via WebKit/PDFKit — handy for logos and icons), video thumbnails via `AVAssetImageGenerator`; QuickLook (`QLThumbnailGenerator`) fallback for everything else.
14. **Video & GIF playback**:
    - **In the grid**: play videos & GIFs right in the cells (Settings toggle, off by default) — `AVPlayerLayer`-backed cells for video, animated image view for GIFs; only animate visible cells.
    - **In the expanded view, real video controls**: scrub the timeline, **P** play/pause, **A/D** step frames, **M** mute, **⌘⇧S saves the exact frame to Inbox** as a new image item.
15. **Endlessly customizable**: Settings (⌘,) — grid spacing, corner radius, grid background (system/custom color), light/dark/system appearance, thumbnail fill vs fit, default zoom, **selection color (blue, grey, primary, orange)**, show/hide like badges, grid video/GIF autoplay, virtual-copies toggle, menu bar icon, extension server. Persist via `@AppStorage`; apply live.
16. **Blazing fast — tested against a 50K-item library.** Thumbnails via `CGImageSourceCreateThumbnailAtIndex` downsampling on a background executor, disk-cached inside the library (app cache for connected folders), in-memory `NSCache` LRU on top. Grid renders decoded `CGImage`s only for visible rows. Persisted index so launch → pixels is instant (no grey placeholders). Generate a 50K synthetic fixture and profile scrolling, zooming, launch, and search against it.
17. **Localization**: String Catalogs from day one (all UI strings localizable). Ship English + French, German, Spanish, Italian, Ukrainian, Simplified Chinese, Japanese, **Portuguese (Brazil)** (machine-translated first pass is fine for an OSS project; mark for review).

## Interaction & motion (the part that must feel Apple-native)

- **Grid**: justified-rows layout (like Eagle/Atlas) implemented as a custom SwiftUI `Layout` over precomputed rows inside a `LazyVStack`. Zoom via: bottom-right slider, **trackpad pinch** (`MagnifyGesture`), **⌘-scroll wheel** (mouse users), and ⌘+/⌘−, animating cell size smoothly and keeping content under the cursor anchored — like Apple Photos. First-class mouse support throughout (no trackpad-only interactions).
- **Pan like Figma**: space + drag, or middle-mouse-button drag, pans the scroll view (grid and zoomed detail).
- **Shared transitions**: click/space on an item → detail expands from the cell using `matchedGeometryEffect` (namespace shared between grid cell and detail overlay; in-window overlay, not a navigation push, so geometry actually matches). Dismiss reverses into the cell. Interactive: Escape, click outside, or pinch-in closes.
- **Space to open, Quick Look style — also works on hover**: Space opens the hovered item even without selection (like Atlas). Arrow keys flip between items while open, **with no white flash** — keep the previous image up until the next one is decoded (crossfade, never blank).
- **Detail view**: scroll-wheel/trackpad pan when zoomed, pinch or ⌘-scroll to zoom, double-click toggles fit/100%; video controls per §14.
- **Drag & drop is a fundamental**: drop files/folders/images/URLs from Finder, browsers, other apps onto the grid (import to current collection), onto a sidebar collection, onto the menu bar icon (Inbox). `.dropDestination`/`DropDelegate` with `NSItemProvider` file-promise support (browser drags are promises). Drag items *out* to Finder (export copies) and between collections. Insertion/highlight states during drag-over. Drag-to-reorder items when sort = Custom.
- **Selection**: click, ⌘-click, shift-range, rubber-band; selection ring uses the user's chosen selection color.
- **Reduced motion**: respect `accessibilityReduceMotion` *and* offer an in-app "Reduce motion" setting (like Atlas) — crossfade instead of geometry zoom, no bouncy springs.

## Architecture

```
Aigle/
  project.yml                 # xcodegen
  Aigle/                      # app target (SwiftUI, macOS 26)
    App/                      # AigleApp, MenuBarExtra, Settings scene, commands (⌘K, ⌘T, ⌘⇧S…)
    Core/
      Library/                # LibraryStore (actor), models (Item, Collection, VirtualCopy),
                              # Eagle codec, bookmarks, coordinated IO, FSEvents watcher,
                              # trash, custom-order persistence, persisted launch index
      Thumbs/                 # ThumbnailPipeline (actor), disk+memory cache, SVG/PDF/video renderers
      Search/                 # ⌘K index (library + connected folders)
      Server/                 # ExtensionServer (NWListener HTTP)
      LinkFetch/              # URL metadata fetcher
    UI/
      Sidebar/  Grid/  Detail/  Inspector/  Search/  Onboarding/  Settings/  Components/
  AigleSafari/                # Safari Web Extension target (embedded in app)
  AigleTests/                 # Eagle round-trip, import, index, search, link-parse tests
  extension/                  # Chrome MV3 extension (plain JS)
  README.md
```

- `LibraryStore` is a Swift actor owning the on-disk library + in-memory index (`[Item]`, collection tree, tag set, custom orders, virtual-copy map). UI observes an `@Observable LibraryViewModel` snapshot on the main actor. Mutations go store → disk (coordinated write) → publish new snapshot. External changes (FSEvents on the library folder) re-sync. Index snapshot persisted to disk for instant launch.
- Concurrency: Swift 6 strict; background work in actors; never block the main thread.
- No third-party dependencies. Apple frameworks only.

## Phases (build + run after each; keep the app bootable at every step)

1. **Scaffold**: project.yml, sandbox + entitlements, app boots to onboarding; create/open library (incl. picking an Eagle library); security-scoped bookmark persistence; reopen last library on launch; String Catalog wired up. `git init` (no commits unless the user asks).
2. **Store + grid + import**: Eagle-format codec + tests; drag-drop + paste import; virtual-copy dedupe; thumbnail pipeline (images, SVG, PDF, video); justified grid; zoom (slider, pinch, ⌘-scroll, ⌘±); selection + selection colors; context menu (rename, like, delete→trash, reveal in Finder); sort menu incl. custom order with drag-to-reorder.
3. **Sidebar & collections**: tree with nesting/reorder/drag-into, alphabetical sort action, counts, All/Inbox/Likes/Trash, empty-trash confirm; persisted launch index (instant open, no placeholders).
4. **Detail + motion**: matched-geometry open/close; Space-to-open incl. hover; arrow-key flipping with no-flash crossfade; zoom/pan + space/middle-mouse panning; inspector (name, tags, dimensions, annotation, like); ⌘T tag editor; reduce-motion paths (system + in-app toggle).
5. **Connected folders**: add/remove, FSEvents live updates, background preview preparation, persisted per-folder index, sidebar section.
6. **Search + likes polish + links + menu bar**: ⌘K palette (library + connected folders); ⌥-click quick-like + badges; link items with metadata fetch; MenuBarExtra drop target.
7. **Video/GIF playback**: in-grid autoplay (toggle); expanded-view player with scrubber, P/A/D/M keys, ⌘⇧S save-frame-to-Inbox.
8. **Extensions**: NWListener endpoint + token; Chrome MV3 in `extension/`; Safari Web Extension target embedded in the app with Settings toggle; end-to-end test with curl + Safari.
9. **Hardening & polish**: Eagle import validation against fixture; run `audit-xcode-security-settings`; **50K-item synthetic library performance pass** (launch, scroll, zoom, search — no hitches); localization pass (8 languages); Settings complete; README with screenshots; final `xcodebuild` clean + tests green; launch app and screenshot for verification.

## Non-goals (for now)

iOS companion app, MCP support, Canvas/Infinity view modes (Grid only; leave the view-mode switcher stubbed to Grid — Figma-style space-drag panning still applies to the grid and zoomed detail), cloud accounts/sync service (iCloud is just a folder location), auto-updates (Sparkle can come later — OSS users build from source or get releases).
