---
name: run-aigle
description: Build, launch, screenshot and drive the Aigle macOS app — use when asked to run Aigle, start the app, take a screenshot of the UI, click through the interface, open a library, verify a UI change visually, or run the test suite.
---

# Running Aigle

Aigle is a sandboxed native SwiftUI app for macOS. There is no headless mode and
no test hook that opens a library, so seeing the UI means running the real app
and driving it through the accessibility and CoreGraphics event APIs.

`driver.sh` wraps all of that. **Use it instead of hand-rolling `osascript`** —
several of the obvious approaches silently do nothing here (see Gotchas).

All paths below are relative to the repo root. The driver resolves its own
paths, so you can call it from anywhere.

```bash
.claude/skills/run-aigle/driver.sh help
```

## Prerequisites

macOS on Apple silicon, plus:

```bash
brew install xcodegen
```

**Two TCC permissions are required**, and both are denied by default. Neither
failure says "permission" — screenshots come back empty and clicks do nothing:

```bash
.claude/skills/run-aigle/driver.sh perms
# screen-recording  ok
# accessibility     ok
```

Anything `DENIED` must be granted by the user in System Settings ▸ Privacy &
Security (Screen & System Audio Recording, and Accessibility) for the terminal
app running the agent. You cannot grant these yourself — ask.

`driver.sh windows` is the one observation command that needs **no** permission,
so use it to check whether the app is up before diagnosing a TCC problem.

## Build

```bash
.claude/skills/run-aigle/driver.sh build   # xcodegen generate + xcodebuild, prints the .app path
.claude/skills/run-aigle/driver.sh test    # 68 tests / 14 suites, failures only
```

`Aigle.xcodeproj` is generated and gitignored — `project.yml` is the source of
truth, and `build` regenerates it every time. Re-run after adding files.

The README says **Xcode 26.6+**. That is conservative: this was built and fully
tested on **Xcode 26.5 (17F42) / macOS 26.5.2**. Don't let a 26.5 toolchain stop
you.

## Run (agent path)

One command proves the whole chain — build, launch, capture, assert the window
actually painted:

```bash
.claude/skills/run-aigle/driver.sh smoke
# → .aigle-run/smoke.png
```

Then drive it:

```bash
D=.claude/skills/run-aigle/driver.sh

$D launch                      # waits for a window, parks it, then lists it
$D windows                     # id  pid  owner  w  h  x  y  title
$D ui                          # accessibility tree, with @x,y for click targets
$D shot out.png                # ONE window, isolated — not the whole screen
$D click Inspector             # by label — re-resolves coordinates itself
$D click-at 1123 353           # real CGEvent click (see Gotchas)
$D click-at 1284 353 cmd       # extend selection
$D click-at 1123 353 double    # open the detail view
$D hover 1123 353              # pointer only — the grid's hover lift needs this
$D menu File "Close Library"
$D key escape
$D quit
```

**Prefer `click <label>` when a label exists.** It runs `ui` and clicks the
result in one shot, so it can't act on a stale coordinate — and window geometry
here is *not* stable between commands (see Gotchas). Labels come from `.help()`
tooltips, so it works on the toolbar (`Inspector`, `Import`, `Sort`, `Search`,
`Hide Sidebar`, `Add`) and almost nowhere else. Everything in the sidebar and
grid is an unlabeled `AXRow`/`AXImage` — for those, `ui` then `click-at`,
back to back.

### Coordinates — read this before clicking anything

**Always `place` the window before computing a click.** `launch` does it for
you; do it again by hand if the window may have moved:

```bash
$D place           # → "placed: 100,100 1280x820 (CGWindowList and AX agree)"
```

`place` sets the frame, reads it back, waits, and reads it back *again* — macOS
window restoration lands a second or two after launch and will otherwise drag
the window to whatever display it was last on (seen here: x = `-1905`, and once
`-2341`). It retries until the position sticks, so trust its output over your
memory of where you put the window.

That "agree" is the whole point. On a secondary or scaled display the two
coordinate systems report **different origins and different sizes for the same
window** — measured here: `598x383 @42,594` (CGWindowList) versus
`1280x820 @416,139` (accessibility), the same window at a 2.14× offset. Clicks
computed in either space then land nowhere, with no error. `place` moves the
window to the primary display, which collapses the two spaces onto each other,
and warns loudly if they still disagree.

Once placed, both of these are true and interchangeable:

- `ui` prints usable screen coordinates directly.
- `screen = image + window origin`, from `$D win-origin` (e.g. `100 100`).

**And coordinates expire.** The window can move and resize between two of your
commands (a window manager, a display change). Read `ui` and click in the same
breath; don't carry a coordinate across a step you didn't expect to move things.

### Opening a library — the only unavoidable GUI step

`LibraryController` mints a security-scoped bookmark from the URL `NSOpenPanel`
hands back. There is **no CLI path, no launch argument and no deep link** that
opens a library; that is the sandbox working as intended, not a gap to route
around. So: get the panel on screen, then let the driver fill it in.

The setup assistant also **gates the main window** — opening a library is not
enough, you must walk to the end of the assistant. Full cold-start sequence,
verified end to end:

```bash
$D demo-library ~/"Aigle Demo.library"   # 24 items, nested collections, tags
$D launch
$D ui                                    # which step are we on?

# Welcome step:  click "Get started"        (bottom right)
$D click-at 1293 890

# Library step:  click the "Open a library" card, then fill the panel
$D click-at 1095 330
$D open-library ~/"Aigle Demo.library"   # → "opened: …", card shows a green check

# Walk out of the assistant:
$D click-at 1210 890                     # "Skip the rest"
$D click-at 1277 890                     # "Start using Aigle"

$D shot grid.png                         # window title is now "All Items"
```

Those coordinates hold for a 1280x820 window parked at `100,100` — i.e. exactly
what `place` gives you. Re-check with `ui` if you use a different size.

`open-library` **polls** for the panel rather than assuming it is up, so you can
call it right after the card click; the sandbox Powerbox takes 3–4 seconds to
draw it. It waits the same way for the cmd-shift-G go-to sheet. If it returns
`no Open panel …`, the card click itself missed.

Once setup has been completed, the library sticks: a clean `quit` and `launch`
comes straight back to `All Items` with the same library, so you pay for the
panel once per machine. Two caveats:

- The assistant resumes where you left it, and **File ▸ Close Library** sends
  you back into it. So a later `launch` may land on any step — run `ui` or
  `windows` first rather than assuming. A window titled `Aigle` means you are in
  the assistant; the main window is titled `All Items` (or the selected view).
- If `quit` has to escalate to a kill (see Gotchas), the app never gets to save,
  and you are back at the Welcome step with no library — verified.

There is no "Open Library" item in the File menu. The route back to the picker
is **File ▸ Close Library**, which returns you to the assistant.

### Importing without the GUI

The app registers `aigle://` and imports into the *already open* library:

```bash
$D deeplink "https://example.com/" page    # or: image | video
```

Only `aigle://save?url=…&type=…` is handled; every other URL — including
`file://` — is dropped by the guard in `DeepLink.handle`. This is the only
programmatic way to change library contents while the app is running.

## Run (human path)

```bash
open "$(.claude/skills/run-aigle/driver.sh app-path)"
```

Or open `Aigle.xcodeproj` in Xcode and hit Run. Fine for a human; useless to an
agent on its own, because nothing here lets you observe or click the result.

## Gotchas

Each of these cost real debugging time:

- **`swift script.swift` recompiles every call — and that latency eats your
  clicks.** It costs 1–2 seconds, which sits precisely between "make Aigle
  frontmost" and "post the click"; focus returns to the terminal in the gap and
  the click is delivered to a window that is no longer key, silently doing
  nothing. `driver.sh` compiles its helpers once into `.claude/skills/run-aigle/.bin/`
  (gitignored, rebuilt when the source changes): 4.0s → 0.06s per call. Don't
  call the `.swift` files with the interpreter directly.

- **`set frontmost to true` is not enough to make clicks land.** It marks the
  *process* frontmost without necessarily making its window key. Verified:
  clicking "Get started" with `frontmost` set did nothing three times running,
  then worked on the first click after `tell application "Aigle" to activate`.
  The driver's `focus` does both — `activate` for the key window, `set
  frontmost` for the accessibility tree.

- **`quit` does not necessarily quit.** With the assistant's "Keep the menu bar
  icon" option on, the quit event closes the window and leaves the process
  alive — and the window-close can land *seconds later*, i.e. after your next
  `launch` already saw the old window, which made `smoke` fail with "no Aigle
  window" immediately after reporting "up". `driver.sh quit` waits 8s for a real
  exit and then kills. Note the cost: a killed app never saves, so the library
  is gone and you restart at the Welcome step.

- **CGWindowList transiently loses the window when it is occluded.**
  `.optionOnScreenOnly` drops windows that aren't actually being displayed, so
  `windows` can print nothing while the app is perfectly healthy — usually
  because your terminal is in front. `shot` retries once behind a `focus` before
  believing it. Don't read one empty result as "the app died".

- **The accessibility tree is EMPTY unless Aigle is frontmost.** `windows of
  process "Aigle"` returns an empty list — not an error — when the app is in
  the background, so `ui` prints nothing and `place` fails, both silently,
  while `windows` (CGWindowList) cheerfully reports the window. Every driver
  subcommand that touches accessibility calls `focus` first. If you hand-roll
  `osascript`, activate the process yourself or you will debug a ghost.

- **Window geometry is not stable between two commands.** Observed on this
  machine: a window parked at `100,100 1280x820` was at `-951,475 898x843` two
  commands later, with nothing in between but a keystroke — a third-party
  window manager and a multi-display arrangement will move and resize it behind
  your back. Never reuse coordinates from an earlier `ui` dump. Either `place`
  immediately before clicking, or use `click <label>`, which re-resolves.

- **The app can be running with zero windows.** The setup assistant's "Keep the
  menu bar icon, so you can drop things in with the window closed" option lets
  the last window close without terminating the app, so `running` says `yes`
  while `windows` and `ui` both come back empty. `launch` is the fix — it
  re-`open`s and gets a window back. Expect that window to reappear on a
  secondary display (seen here at x = **-2341**); `launch` re-parks it for you.

- **Clicking a toolbar button sometimes also pops the toolbar's own display-mode
  menu** ("Icon and Text / Icon Only / Text Only") on top of the result. The
  underlying click still lands — the Inspector really did toggle. Send
  `key escape` and carry on; it did not reproduce on a second attempt.

- **CGWindowList and the accessibility API disagree about window geometry on a
  secondary or scaled display** — different origin *and* different size for the
  same window, seen here 2.14× apart. Every click computed from either then
  misses silently. Run `place` first; it normalises this and warns if it can't.
  This is the single most expensive trap here: nothing errors, clicks just
  stop working.

- **The setup assistant gates the main window.** Opening a library leaves you
  in the assistant; you still have to click "Skip the rest" then "Start using
  Aigle" before the grid exists. A `windows` title of `Aigle` means you are
  still in the assistant — the main window is titled `All Items` (or whatever
  view is selected).

- **`osascript … click at {x, y}` silently does nothing** on the grid, the
  sidebar and most controls. It dispatches through the accessibility layer, and
  SwiftUI's views expose no `AXPress` action to receive it — the click is
  swallowed with no error. `click-at` posts a real `CGEvent` (`mouse.swift`)
  instead. Use it for everything.

- **The Open panel is a *sheet*, and it is drawn by another process.**
  `CGWindowList` reports a window titled `Open` owned by Aigle, which is
  misleading. In the accessibility tree it is `sheet 1 of window 1 of process
  "Aigle"`. The pixels belong to
  `com.apple.appkit.xpc.openAndSavePanelService` (the sandbox Powerbox), and
  querying *that* process returns **zero** windows. Always go through Aigle.

- **Never type a path into the panel character by character.** Per-character
  keystrokes race the panel's path autocomplete, which drops characters; a
  follow-up Return then lands somewhere unintended. Once this quit the app
  outright mid-automation (a clean exit, not a crash — no `.ips` report). The
  driver sets the go-to field's `value` atomically instead.

- **Most controls have no accessibility label.** SwiftUI buttons come back as
  bare `AXButton` with no `AXTitle` and no `AXDescription`, so `click <label>`
  only works on the toolbar (those carry `.help()`, which surfaces as `AXHelp`).
  `ui` falls back through `AXHelp`/`AXValue`/`AXIdentifier` and prints `@x,y`
  for every unlabeled control — click those coordinates instead.

- **Don't reach for `every UI element … whose name is` in AppleScript.** It
  raises `-1700` ("Can't make … into type specifier") on this app's tree rather
  than returning an empty list. `click <label>` greps the `ui` traversal for the
  label and clicks its `@x,y` with a real `CGEvent`, which is why it works.

- **`AXIdentifier` leaks whole mangled SwiftUI generic type names** — one is
  ~900 characters and buries the rest of the tree. `ui` truncates at 80.

- **`open aigle://…` opens an additional window** rather than reusing the front
  one. After a deep link, `windows` shows two; `shot` targets the largest by
  area, which may not be the one you were watching. Pass an explicit window id
  as the second argument to `shot`.

- **The test host spews `[Connection] … com.apple.linkd.autoShortcut` XPC
  errors** on every run. Harmless sandbox noise, but it contains `error:`, so a
  naive grep reports failures that aren't there. `driver.sh test` filters it.

- **Screenshot the window, never the screen.** `shot` uses
  `screencapture -x -o -l <id>`, which isolates one window. A full-screen grab
  on a developer's machine pulls their unrelated windows into the transcript.

- **`driver.sh` steals keyboard focus** for anything using System Events or
  posting a click (`ui`, `place`, `click`, `click-at`, `key`, `menu`,
  `open-library`). If a human is at the machine, that interrupts them. `windows`
  never steals focus and `shot` only does so on its retry — prefer those two
  when you just need to look.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `winlist: no windows for Aigle` | App isn't running. `driver.sh launch`. |
| `empty capture — Screen Recording permission?` | Grant Screen & System Audio Recording, then restart the terminal app. |
| `ui` prints `Aigle is not running` but `windows` lists windows | Accessibility not granted. `driver.sh perms`. |
| `ui` prints **nothing at all** | Not a permission problem — the app wasn't frontmost when the tree was read. The driver now focuses first; if you hand-rolled `osascript`, activate the process. |
| `no Aigle window (running: yes)` | Windowless: the menu-bar-icon option kept the app alive with no window. `driver.sh launch`. |
| `Can't get window 1 of process "Aigle". Invalid index. (-1719)` | Same thing — app in the background, or genuinely windowless. Focus it, or `launch`. |
| `no Open panel — click the 'Open a library' card first` | The panel isn't up. `driver.sh ui`, find the card, `click-at` it. |
| `no clickable element labelled 'X'` | The control has no `.help()` tooltip. `driver.sh ui`, take its `@x,y`, `click-at` that. |
| Clicks land but nothing selects | You used System Events' `click at`, not the driver. Use `click-at`. |
| `click-at` reports success but the UI never changes | Coordinates are stale — the window moved between your `ui` and your click. `driver.sh place`, re-read `ui`, click immediately. |
| A "Icon and Text / Icon Only / Text Only" menu appears after a toolbar click | Toolbar display-mode menu; the click itself still worked. `driver.sh key escape`. |
| `place` warns "coordinate spaces disagree" | Window could not be moved to the primary display — move it by hand, or reduce the requested size. |
| `window would not stay at 100,100` | Window restoration or a third-party window manager keeps dragging it back. Quit the window manager, or work from `ui` coordinates only (they stay correct; only image-offset arithmetic breaks). |
| `the go-to sheet (cmd-shift-G) never opened` | Transient; re-run `open-library`, the panel is still up. |
| `windows` prints nothing but the app is clearly fine | The window is occluded, so `.optionOnScreenOnly` hides it. Bring Aigle forward and re-run. |
| Setup restarts at Welcome with no library | The previous `quit` escalated to a kill, so nothing was saved. Re-open the library through the panel. |
| Library opened but there is no grid | Still inside the setup assistant. Click "Skip the rest", then "Start using Aigle". |
| `could not resolve BUILT_PRODUCTS_DIR` | Never built. `driver.sh build`. |
| `xcodegen missing` | `brew install xcodegen`. |
| App launches to the setup assistant unexpectedly | Setup resumes where it left off, and Close Library sends you back. Walk forward, or reopen the library. |

## Files

| File | Purpose |
|---|---|
| `driver.sh` | Everything above. Start here. |
| `winlist.swift` | Window list via `CGWindowListCopyWindowInfo` — needs no TCC grant. |
| `mouse.swift` | Real `CGEvent` clicks, because AX clicks don't work here. |
| `make-demo-library.swift` | Generates a 24-item Eagle-format library with real artwork. |
| `.bin/` | Compiled helpers, cached by the driver. Gitignored; delete to force a rebuild. |
