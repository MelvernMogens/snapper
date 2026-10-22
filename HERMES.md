# Snapper

## What this is
A native macOS menu-bar screenshot and recording app built to be a CleanShot X replacement for Melvern's own Mac:
area / window / fullscreen / previous-area / self-timer capture over a frozen screen with a pixel loupe,
Quick Access thumbnails, an Annotate editor, pin-to-screen, OCR, scrolling capture, MP4/GIF recording
and a capture history. It is personal and not distributed: it is ad-hoc signed and there is no cloud upload.

## Stack
- **Swift 6 / SwiftPM, AppKit** (SwiftUI only inside Settings). There is no Xcode project: SwiftPM builds fine and avoids a noisy pbxproj.
- **ScreenCaptureKit** for every pixel (stills via SCScreenshotManager, video via SCStream + AVAssetWriter). Snapper's own windows are always excluded from captures.
- **Vision** for OCR and **ImageIO** for PNG/JPEG/GIF encoding. There are no third-party dependencies.
- **Carbon RegisterEventHotKey** for global shortcuts. It needs no Accessibility permission.
- `SnapKit` library = pure logic (geometry, naming, prefs, history, stitcher, annotation model). It is unit-tested.
- **Rejected:** Electron/Tauri (no ScreenCaptureKit, 100 MB), and the `screencapture` CLI (no freeze-frame, no loupe, slow).

## Commands
```bash
swift build && swift test                 # debug build + SnapKit unit tests
.build/debug/Snapper --help               # list headless CLI commands (verification without UI)
.build/debug/Snapper --probe              # permission + screens + save dir + history count
.build/debug/Snapper --capture-rect 0,0,800,500 /tmp/a.png   # global AppKit points -> PNG
scripts/build-app.sh [--install]          # build/Snapper.app; --install -> /Applications + launch
swift scripts/make-icon.swift             # regenerate Resources/AppIcon.icns
```
Shortcuts: ⌥⌘3 full, ⌥⌘4 area, ⌥⌘5 window, ⌥⌘6 previous area, ⌥⌘7 record, ⌥⌘8 OCR, ⌥⌘9 history, ⌥⌘0 scrolling.
In the overlay: Space = window mode (or move the selection while dragging), Shift = square, Return = full screen, Esc = cancel.

## Gotchas
- An ad-hoc signature changes on every build, so macOS can ask for Screen Recording again after a reinstall. Remove the app from the list and re-grant it.
- Coordinates: the overlay works in AppKit global points (bottom-left origin) and CGWindowList uses Quartz (top-left). `Geo.quartzToAppKit` / `Geo.pixelRect` are the only conversions and both are tested.

## Milestones — status and which model to use
Product scope, non-goals, and open questions live in `docs/prd.md`.

| # | Scope | Status | Model / effort |
|---|---|---|---|
| M1 | Capture core: overlay + loupe, area/window/full/previous/timer, Quick Access, history store, hotkeys, CLI | done | Opus / high |
| M2 | Annotate editor (arrow, shapes, text, blur, highlight, counter, spotlight, crop, undo, background) | in progress | Opus / high |
| M3 | Recording: MP4 + GIF, click rings, pause/restart, menu-bar timer | in progress | Opus / high |
| M4 | Tools: OCR, pin, scrolling capture, history window, settings, icon | in progress | Opus / high |
| M5 | Integration polish: install, real-use pass, fix papercuts | todo | Opus / high |

**State the model and effort at the start of every milestone, before working.**

## Conventions
- Ask before adding a dependency (the answer is almost always no).
- Every feature exposes a headless `--xyz` CLI in `registerCLI()` so it can be verified without clicking.
- UI taste: compact dark chrome, small SF-symbol icons, no big round buttons, no toast for routine actions.

## House rules
- Run `swift test` before adding to working code, and report the real numbers afterwards.
- If the diff contradicts a sentence in a doc, that sentence is part of the diff.
- Never add a Co-Authored-By trailer.
