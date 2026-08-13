#!/bin/bash
# Aigle driver — build, launch and poke a sandboxed macOS SwiftUI app.
#
# Aigle has no headless mode and no test hook for opening a library, so the only
# way to see the UI is to run the real app and drive it through the same
# accessibility APIs a screen reader uses. This wraps that.
#
#   ./driver.sh help
#
# Paths in here are resolved relative to the repo root, not the caller's cwd.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SHOTS="${AIGLE_SHOTS:-$ROOT/.aigle-run}"
APP_NAME="Aigle"

log() { printf '\033[2m» %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Run a helper .swift as a CACHED BINARY, not through the interpreter.
#
# `swift foo.swift` recompiles every single time — 1-2 seconds. That delay sits
# between "make Aigle frontmost" and "post the click", which is long enough for
# focus to go back to the terminal, and the click is then delivered to a window
# that is no longer key and quietly does nothing. Compiling once removes the
# gap. Binaries live in .bin/ (gitignored) and rebuild when the source changes.
BIN="$HERE/.bin"
swiftrun() {
  local src="$1"; shift
  local out="$BIN/$(basename "$src" .swift)"
  if [ ! -x "$out" ] || [ "$HERE/$src" -nt "$out" ]; then
    mkdir -p "$BIN"
    swiftc -O -o "$out" "$HERE/$src" 2>/dev/null || die "could not compile $src"
  fi
  "$out" "$@"
}

# Every accessibility query and every click must be preceded by this.
#
# Two separate reasons, and they need two different AppleScripts:
#
#  * When Aigle is not frontmost, `windows of process "Aigle"` returns an EMPTY
#    LIST — not an error — even though CGWindowList happily reports the window.
#    `ui` then prints nothing and `place` fails, both silently.
#  * `set frontmost to true` marks the PROCESS frontmost without necessarily
#    making its window key. Clicks posted in that state are eaten: verified by
#    clicking "Get started" with `frontmost` set and watching the assistant not
#    advance, then advancing on the first click after an `activate`.
#
# So: `activate` for the key window, `set frontmost` for the AX tree.
focus() {
  osascript -e 'tell application "Aigle" to activate' >/dev/null 2>&1 || true
  osascript -e 'tell application "System Events" to tell process "Aigle" to set frontmost to true' >/dev/null 2>&1 || true
  sleep 0.5
}

# ---------------------------------------------------------------- build

app_path() {
  # -showBuildSettings is slow (~3s) but it is the only honest answer; the
  # DerivedData hash is not predictable from the project name alone.
  local dir
  dir=$(cd "$ROOT" && xcodebuild -project Aigle.xcodeproj -scheme Aigle \
        -configuration Debug -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
  [ -n "$dir" ] || die "could not resolve BUILT_PRODUCTS_DIR — has it been built?"
  echo "$dir/$APP_NAME.app"
}

cmd_build() {
  command -v xcodegen >/dev/null || die "xcodegen missing — brew install xcodegen"
  cd "$ROOT"
  log "xcodegen generate"
  xcodegen generate >/dev/null
  log "xcodebuild build"
  xcodebuild -project Aigle.xcodeproj -scheme Aigle -configuration Debug build \
    >"$SHOTS/build.log" 2>&1 || { tail -40 "$SHOTS/build.log"; die "build failed (full log: $SHOTS/build.log)"; }
  app_path
}

cmd_test() {
  cd "$ROOT"
  # The test host logs a stream of "[Connection] ... com.apple.linkd.autoShortcut"
  # XPC errors on every run. They are harmless sandbox noise, not test failures,
  # but they contain "error:" so they survive a naive filter — drop them here.
  xcodebuild -project Aigle.xcodeproj -scheme Aigle -destination 'platform=macOS' test 2>&1 \
    | grep -vE '\[Connection\]|linkd\.autoShortcut' \
    | grep -E '✔ Test run|✘|[0-9]+: error:|TEST (SUCCEEDED|FAILED)' || true
}

# ---------------------------------------------------------------- lifecycle

cmd_launch() {
  local app; app=$(app_path)
  [ -d "$app" ] || die "not built yet — run: $0 build"
  open "$app"
  # Wait for a real window rather than sleeping a fixed amount; first launch
  # after a build is much slower than a warm one.
  for _ in $(seq 1 40); do
    if swiftrun winlist.swift "$APP_NAME" >/dev/null 2>&1; then
      log "up"
      # Always park the window somewhere predictable, or every later click is a
      # coin flip on a multi-display setup. See cmd_place.
      cmd_place >/dev/null || true   # keep stderr: the coordinate warning matters
      cmd_windows; return 0
    fi
    sleep 0.5
  done
  die "no $APP_NAME window appeared within 20s"
}

aigle_pid() { pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null | head -1; }

# Quit and WAIT for the process to actually go.
#
# A plain `tell application "Aigle" to quit` frequently leaves it alive — the
# setup assistant's menu-bar-icon option keeps the app running with no window —
# and, worse, the window-close it does trigger can land a couple of seconds
# later, i.e. after the next `launch` already saw the old window. That made
# `smoke` fail with "no Aigle window" straight after reporting "up". So: ask
# nicely, wait, then escalate.
cmd_quit() {
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 16); do
    [ -n "$(aigle_pid)" ] || { echo "quit"; return 0; }
    sleep 0.5
  done
  local pid; pid=$(aigle_pid)
  log "still alive after 8s (menu-bar icon) — killing $pid"
  kill "$pid" 2>/dev/null || true
  sleep 1
  [ -z "$(aigle_pid)" ] && echo "quit (killed)" || die "could not terminate $APP_NAME"
}

cmd_running() { [ -n "$(aigle_pid)" ] && echo yes || echo no; }

# ---------------------------------------------------------------- observe

# Needs no TCC permission at all — safe first probe on an unknown machine.
cmd_windows() { swiftrun winlist.swift "$APP_NAME"; }

# Largest Aigle window, which is the document window rather than a panel.
main_window_id() {
  swiftrun winlist.swift "$APP_NAME" 2>/dev/null \
    | awk -F'\t' '{area=$4*$5; if (area>max) {max=area; id=$1}} END{if (id) print id}'
}

# Screenshot ONE window, not the whole screen. -l isolates the window, so the
# shot is unaffected by whatever else the human has on their desktop, and does
# not leak their other windows into the transcript.
cmd_shot() {
  local out="${1:-$SHOTS/aigle-$(date +%H%M%S).png}"
  local id="${2:-$(main_window_id)}"
  # CGWindowList's .optionOnScreenOnly drops the window whenever it is not
  # actually being displayed — behind another app, on another Space. So an empty
  # result does NOT mean "not running": bring Aigle forward and ask again before
  # believing it. Deliberately only on the retry, so the common case still costs
  # nobody their keyboard focus.
  if [ -z "$id" ]; then
    focus
    id=$(main_window_id)
  fi
  # If it is STILL empty, Aigle is genuinely windowless — the setup assistant's
  # "keep the menu bar icon" option lets the last window close without
  # terminating the app, so `running` says yes while every window query is
  # empty. `launch` re-opens one (and re-parks it: a restored window tends to
  # come back on a secondary display).
  [ -n "$id" ] || die "no $APP_NAME window (running: $(cmd_running)) — run: $0 launch"
  mkdir -p "$(dirname "$out")"
  screencapture -x -o -l "$id" "$out" 2>/dev/null
  [ -s "$out" ] || die "empty capture — Screen Recording permission? ($0 perms)"
  local px; px=$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  echo "$out (${px}px, $(du -h "$out" | cut -f1))"
}

# The accessibility tree is how you find things to click without guessing
# coordinates.
#
# Most of this app's controls are SwiftUI buttons with NO AXTitle and NO
# AXDescription — they come back as bare "AXButton". So every label attribute is
# tried in turn (AXHelp catches anything given a .help() modifier), and unlabeled
# elements still print their centre point, which is what `click-at` consumes.
# An unlabeled row here is a click target, not noise.
cmd_ui() {
  focus
  osascript <<'AS' 2>&1 | sed '/^[[:space:]]*$/d'
on label(e)
  tell application "System Events"
    repeat with attr in {"AXTitle", "AXDescription", "AXHelp", "AXValue", "AXIdentifier"}
      try
        set v to value of attribute attr of e
        if v is not missing value then
          set v to v as text
          -- SwiftUI leaks whole mangled generic type names into AXIdentifier;
          -- one of them is 900 characters wide and buries the real tree.
          if (count of v) > 80 then set v to (text 1 thru 77 of v) & "..."
          if v is not "" then return v
        end if
      end try
    end repeat
  end tell
  return ""
end label

on describe(els, depth, out)
  if depth > 7 then return out
  tell application "System Events"
    repeat with e in els
      try
        set r to role of e
        set nm to my label(e)
        set pad to ""
        repeat depth times
          set pad to pad & "  "
        end repeat
        set loc to ""
        if r is in {"AXButton", "AXTextField", "AXCheckBox", "AXPopUpButton", "AXRow", "AXMenuButton", "AXImage"} then
          try
            set p to position of e
            set s to size of e
            set loc to "  @" & ((item 1 of p) + (item 1 of s) div 2) & "," & ((item 2 of p) + (item 2 of s) div 2)
          end try
        end if
        if nm is not "" or loc is not "" then
          set out to out & pad & r & "  " & nm & loc & linefeed
        end if
        try
          set out to my describe(UI elements of e, depth + 1, out)
        end try
      end try
    end repeat
  end tell
  return out
end describe

tell application "System Events"
  if not (exists process "Aigle") then return "Aigle is not running"
  tell process "Aigle"
    set out to ""
    repeat with w in windows
      set out to out & "WINDOW  " & (name of w) & linefeed
      set out to my describe(UI elements of w, 1, out)
    end repeat
    return out
  end tell
end tell
AS
}

# Click a point in screen coordinates — the workhorse, because most controls
# here expose no accessibility label. Get coordinates from `ui`.
#
# This posts a real CGEvent rather than System Events' `click at`, which is
# silently swallowed by SwiftUI content (see mouse.swift).
cmd_click_at() {
  focus
  swiftrun mouse.swift "$@"
}

# Hover without clicking — the grid's lift/shadow only appears under the pointer.
cmd_hover() { swiftrun mouse.swift "$1" "$2" move; }

# Move the window to a known spot on the PRIMARY display, then prove that the
# two coordinate systems agree.
#
# This is not cosmetic. On a secondary or scaled display, CGWindowList and the
# accessibility API report different origins AND different sizes for the same
# window (seen here: 598x383 @42,594 vs 1280x820 @416,139 — same aspect, 2.14x
# apart). Clicks computed in either space then miss, silently. Parking the
# window on the primary display collapses both spaces onto one another.
cmd_place() {
  local x="${1:-100}" y="${2:-100}" w="${3:-1280}" h="${4:-820}"
  # Retry: straight after launch the app is in CGWindowList but its AX window
  # list is still empty, so a single attempt loses a race it would win a second
  # later. Returns non-zero rather than dying — `launch` calls this and must
  # survive it.
  # Two separate races, hence: set, read back, and try again if it didn't take.
  #
  #  * Straight after launch the app is in CGWindowList but its AX window list
  #    is still empty, so the `set position` itself errors.
  #  * macOS window restoration lands AFTER launch and puts the window back on
  #    whatever display it was last on (seen here: x = -1905). A place that
  #    "succeeded" a moment earlier is silently undone.
  #
  # Returns non-zero rather than dying — `launch` calls this and must survive it.
  local cg ax want="$x,$y ${w}x${h}"
  for _ in 1 2 3 4 5 6; do
    focus
    osascript -e "tell application \"System Events\" to tell process \"Aigle\"
      set position of window 1 to {$x, $y}
      set size of window 1 to {$w, $h}
    end tell" >/dev/null 2>&1 || { sleep 1; continue; }
    sleep 0.8
    cg=$(swiftrun winlist.swift "$APP_NAME" | awk -F'\t' '{a=$4*$5; if(a>m){m=a;o=$6","$7" "$4"x"$5}} END{print o}')
    # Not enough that it landed — it has to STAY. Window restoration can arrive
    # a second or two after launch and quietly drag it back to its old display.
    if [ "$cg" = "$want" ]; then
      sleep 1.5
      cg=$(swiftrun winlist.swift "$APP_NAME" | awk -F'\t' '{a=$4*$5; if(a>m){m=a;o=$6","$7" "$4"x"$5}} END{print o}')
      [ "$cg" = "$want" ] && break
    fi
    sleep 1
  done
  if [ "$cg" != "$want" ]; then
    printf '\033[31m✗ window would not stay at %s (it is at %s) — clicks computed from `ui` will still work, but image offsets will not\033[0m\n' "$want" "${cg:-nowhere}" >&2
    return 1
  fi
  ax=$(osascript -e 'tell application "System Events" to tell process "Aigle" to get {position, size} of window 1' \
       | awk -F', ' '{print $1","$2" "$3"x"$4}')
  if [ "$cg" = "$ax" ]; then
    echo "placed: $cg (CGWindowList and AX agree)"
  else
    echo "WARNING: coordinate spaces disagree — CG=$cg AX=$ax" >&2
    echo "  the window is probably on a secondary/scaled display; clicks will miss" >&2
  fi
}

# ---------------------------------------------------------------- interact

# Click by label.
#
# Deliberately NOT `every UI element of entire contents ... whose name is`:
# System Events raises -1700 ("can't make ... into type specifier") on this
# app's tree. Instead reuse the traversal in `ui`, which already resolves labels
# and emits centre points, and click the point with a real CGEvent.
cmd_click() {
  local label="$1" line x y
  line=$(cmd_ui | grep -F "  $label" | grep -o '@[0-9-]*,[0-9-]*' | head -1)
  [ -n "$line" ] || die "no clickable element labelled '$label' — try: $0 ui"
  x=${line#@}; x=${x%,*}
  y=${line#*,}
  cmd_click_at "$x" "$y"
}

cmd_menu() {
  local menu="$1" item="$2"
  osascript -e "tell application \"System Events\" to tell process \"Aigle\"
    set frontmost to true
    delay 0.3
    click menu item \"$item\" of menu 1 of menu bar item \"$menu\" of menu bar 1
  end tell" 2>&1 && echo "menu: $menu > $item"
}

cmd_key() {
  local key="$1" mods="${2:-}"
  local using=""
  [ -n "$mods" ] && using=" using {$(echo "$mods" | sed 's/cmd/command down/g;s/shift/shift down/g;s/opt/option down/g;s/ctrl/control down/g;s/,/, /g')}"
  case "$key" in
    return|enter) key="return" ;;
    esc|escape)   key="escape" ;;
  esac
  if [ "$key" = "return" ] || [ "$key" = "escape" ] || [ "$key" = "tab" ]; then
    osascript -e "tell application \"System Events\" to tell process \"Aigle\"
      set frontmost to true
      delay 0.2
      key code $( [ "$key" = return ] && echo 36 || { [ "$key" = escape ] && echo 53 || echo 48; } )$using
    end tell"
  else
    osascript -e "tell application \"System Events\" to tell process \"Aigle\"
      set frontmost to true
      delay 0.2
      keystroke \"$key\"$using
    end tell"
  fi
  echo "key: $key${mods:+ +$mods}"
}

# The one flow you cannot avoid the GUI for. LibraryController mints a
# security-scoped bookmark from the URL NSOpenPanel hands back, so a library can
# only be opened through the panel — there is no CLI path and no deep link.
#
# Two traps, both of which cost real time to find:
#
#  * The panel is a SHEET on Aigle's window, not a window. CGWindowList reports
#    it as a separate window titled "Open" owned by Aigle, which is misleading —
#    in the accessibility tree it is `sheet 1 of window 1`. It is also drawn by
#    a different process (com.apple.appkit.xpc.openAndSavePanelService, the
#    sandbox Powerbox), and THAT process reports zero windows. Go through Aigle.
#  * Set the go-to field's value; do not type it. Per-character keystrokes race
#    the panel's path autocomplete, which silently eats characters and can leave
#    the panel in a state where a stray Return dismisses the whole app.
cmd_open_library() {
  local path="$1"
  [ -d "$path" ] || die "no such library: $path"
  osascript <<AS 2>&1
tell application "System Events"
  tell process "Aigle"
    set frontmost to true
    delay 0.5

    -- The panel is drawn by the sandbox Powerbox over XPC and routinely takes
    -- 3-4 seconds to show up. A fixed delay here fails intermittently; poll.
    set waited to 0
    repeat until (count of sheets of window 1) > 0 or waited > 10
      delay 0.5
      set waited to waited + 0.5
    end repeat
    if (count of sheets of window 1) is 0 then
      return "no Open panel — click the 'Open a library' card first (driver.sh ui, then click-at)"
    end if
    set panel to sheet 1 of window 1

    -- Same story for the go-to sheet: poll rather than guess a delay.
    keystroke "g" using {command down, shift down}
    set waited to 0
    repeat until (count of sheets of panel) > 0 or waited > 5
      delay 0.25
      set waited to waited + 0.25
    end repeat
    if (count of sheets of panel) is 0 then
      return "the go-to sheet (cmd-shift-G) never opened — retry"
    end if

    -- Atomic set beats keystroke: no autocomplete race, no dropped characters.
    set value of text field 1 of (sheet 1 of panel) to "$path"
    delay 0.6
    key code 36
    delay 1.5
    key code 36
    delay 2.0
    return "opened: $path"
  end tell
end tell
AS
}

# No-GUI seam: the app registers aigle:// and imports into the OPEN library.
# Only host "save" is handled; file URLs are ignored, so this cannot open a
# library — it is for exercising import without touching the UI.
cmd_deeplink() {
  local target="$1" type="${2:-page}"
  open "aigle://save?url=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$target")&type=$type"
  echo "sent: $target ($type)"
}

cmd_demo_library() {
  local dest="${1:-$HOME/Aigle Demo.library}"
  swift "$HERE/make-demo-library.swift" "$dest"
}

# ---------------------------------------------------------------- permissions

# Both of these are denied by default and fail in ways that do not say
# "permission" — check here first when something silently does nothing.
cmd_perms() {
  local tmp; tmp=$(mktemp -t aigleperm).png
  if screencapture -x -o -R 0,0,10,10 "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    echo "screen-recording  ok"
  else
    echo "screen-recording  DENIED → System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording"
  fi
  rm -f "$tmp"

  if osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1; then
    echo "accessibility     ok"
  else
    echo "accessibility     DENIED → System Settings ▸ Privacy & Security ▸ Accessibility"
  fi
}

# ---------------------------------------------------------------- smoke

cmd_smoke() {
  mkdir -p "$SHOTS"
  cmd_perms
  cmd_build >/dev/null
  cmd_quit; sleep 1
  cmd_launch >/dev/null
  sleep 2
  local out="$SHOTS/smoke.png"
  cmd_shot "$out"
  # A window that launched but painted nothing still produces a valid PNG, so
  # check the pixels: a blank frame compresses to almost nothing.
  local bytes; bytes=$(stat -f%z "$out")
  [ "$bytes" -gt 20000 ] || die "capture is only ${bytes}B — window likely blank"
  echo "smoke ok → $out"
}

mkdir -p "$SHOTS"

case "${1:-help}" in
  build)         shift; cmd_build "$@" ;;
  test)          shift; cmd_test "$@" ;;
  app-path)      app_path ;;
  launch)        shift; cmd_launch "$@" ;;
  quit)          cmd_quit ;;
  running)       cmd_running ;;
  windows)       cmd_windows ;;
  shot)          shift; cmd_shot "$@" ;;
  ui)            cmd_ui ;;
  click)         shift; cmd_click "$@" ;;
  click-at)      shift; cmd_click_at "$@" ;;
  hover)         shift; cmd_hover "$@" ;;
  place)         shift; cmd_place "$@" ;;
  win-origin)    swiftrun winlist.swift "$APP_NAME" | awk -F'\t' '{a=$4*$5; if(a>m){m=a;o=$6" "$7}} END{print o}' ;;
  menu)          shift; cmd_menu "$@" ;;
  key)           shift; cmd_key "$@" ;;
  open-library)  shift; cmd_open_library "$@" ;;
  deeplink)      shift; cmd_deeplink "$@" ;;
  demo-library)  shift; cmd_demo_library "$@" ;;
  perms)         cmd_perms ;;
  smoke)         cmd_smoke ;;
  help|*)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'USAGE'

  build                     xcodegen generate + xcodebuild (Debug)
  test                      full test suite, failures only
  app-path                  absolute path to the built .app
  launch                    open the app, wait for a window, list it
  quit | running            lifecycle
  windows                   id/pid/owner/w/h/x/y/title  (needs NO permission)
  shot [out.png] [win-id]   screenshot one window       (needs Screen Recording)
  ui                        accessibility tree + @x,y   (needs Accessibility)
  click <label>             click by label, re-resolving coords (toolbar only —
                            everything else is unlabeled; use ui + click-at)
  click-at <x> <y> [double|cmd|shift]
                            real CGEvent click — the workhorse
  hover <x> <y>             move the pointer without clicking
  place [x y w h]           park the window on the primary display so clicks land
  win-origin                screen x y of the main window (add to image coords)
  menu <Menu> <Item>        click a menu-bar item
  key <key> [cmd,shift]     send a keystroke
  open-library <path>       drive the NSOpenPanel (the only way in — see SKILL.md)
  deeplink <url> [type]     aigle://save — import without the GUI
  demo-library [path]       generate a 24-item library to drive the UI against
  perms                     which TCC grants are missing
  smoke                     build → launch → screenshot → assert non-blank

Screenshots default to .aigle-run/ (override with $AIGLE_SHOTS).
USAGE
    ;;
esac
