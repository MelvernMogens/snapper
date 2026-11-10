# Snapper

**A native macOS menu-bar app for screenshots, annotation and screen recording — a personal CleanShot X.**

CleanShot X is paid per major version and closed. Everything it does day to day is ScreenCaptureKit + Vision + AppKit, which ship with macOS, so Snapper is one Swift package with zero dependencies.

## Features

- **Capture**: area, window, fullscreen, previous area, with a frozen screen, loupe and crosshair (Space = window mode, Shift = square, Esc = cancel)
- **All-In-One (⇧⌘5)**: adjustable selection that remembers the last area, with a toolbar for screenshot, window, fullscreen, scrolling, OCR, pin, video or GIF, exact W×H fields, and a countdown toggle
- **Quick Access card** after each capture: Annotate, Pin, Copy, Save, drag out; swipe away to discard
- **Annotate**: arrow, rectangle, ellipse, line, text, pencil, highlighter, blur / pixelate, spotlight, counter, crop; backgrounds (gradient, solid, image, or your Mac wallpaper)
- **Record**: MP4 (H.264, HEVC above 4K; 30 or 60 fps, Standard / High / Maximum quality) or GIF, for an area, window or full screen
- **OCR**: capture text straight to the clipboard (Vision)
- **Pin** a screenshot as a floating window
- **Scrolling capture**: stitched by image matching
- **History** window with thumbnails
- Settings: PNG / JPEG, folders, launch at login, after-capture behaviour

Not included: cloud upload / share links, video trimming, webcam overlay, keystroke display.

## Shortcuts

| Keys | Action |
|---|---|
| ⇧⌘2 / ⇧⌘3 / ⇧⌘4 / ⇧⌘5 | Window / Fullscreen / Area / All-In-One |
| ⌥⌘6 | Previous area |
| ⌥⌘7 | Record screen (press again to stop) |
| ⌥⌘8 | Capture text (OCR) |
| ⌥⌘9 / ⌥⌘0 | History / Scrolling capture |

The ⇧⌘ keys are the CleanShot layout: Snapper turns the macOS screenshot shortcuts off so they reach it. Untick "Use ⇧⌘2 / ⇧⌘3 / ⇧⌘4 / ⇧⌘5 (CleanShot keys)" in Settings to use ⌥⌘2–⌥⌘5 instead and keep the macOS ones.

## Requirements

- macOS 14 or later
- Swift 5.9+ toolchain (Xcode or Command Line Tools)

## Install

```bash
git clone https://github.com/MelvernMogens/snapper.git && cd snapper
swift test
scripts/make-signing-identity.sh   # one-time, optional: stable local signing identity
scripts/build-app.sh --install     # builds, copies to /Applications, launches
```

On the first capture macOS asks for Screen Recording permission. Grant it, then quit and reopen Snapper.

**Why the signing identity:** an ad-hoc signature changes on every build, so macOS treats each rebuild as a new app and drops the Screen Recording grant. `make-signing-identity.sh` creates a self-signed identity in its own keychain (`~/.snapper-signing`); `build-app.sh` uses it when present and falls back to ad-hoc otherwise. If captures come back wallpaper-only, remove Snapper from Privacy & Security › Screen & System Audio Recording, relaunch, and grant again.

## Commands

| Command | What |
|---|---|
| `swift test` | Unit tests (geometry, naming, history, stitcher, text layout, annotation, recording math) |
| `.build/debug/Snapper --help` | Headless verification commands |
| `.build/debug/Snapper --probe` | Permission, screens, save folder, history count |
| `.build/debug/Snapper --capture-rect 0,0,800,500 /tmp/a.png` | Capture a rect to PNG |
| `scripts/build-app.sh --install` | Build + install the .app |
| `swift scripts/make-icon.swift` | Regenerate `Resources/AppIcon.icns` |

## How it works

```
hotkey / menu ──► ScreenGrabber (ScreenCaptureKit, own windows excluded)
                     │ freeze every display
                     ▼
              Overlay (dim + loupe + crosshair; Space = window mode)
                     │ selection in AppKit global points
                     ▼
              Capture.crop  ──► Output.finish ──► file + clipboard + History copy + sound
                                                     │
                                                     ▼
                                    Quick Access card ─► Annotate · Pin · Copy · Save · drag-out
Recording: SCStream(sourceRect) ─► AVAssetWriter MP4 ─► (GIF: ImageIO) ─► Output.finishMovie
```

| Part | Choice |
|---|---|
| Language / build | Swift 6, SwiftPM (no Xcode project) |
| Capture | ScreenCaptureKit (`SCScreenshotManager`, `SCStream`) |
| Video / GIF | AVAssetWriter H.264 / HEVC, ImageIO GIF |
| OCR | Vision `VNRecognizeTextRequest` |
| Hotkeys | Carbon `RegisterEventHotKey` (no Accessibility permission) |
| Logic + tests | `SnapKit` library + XCTest |

## Project structure

```
Sources/SnapKit/    pure logic: geometry, naming, prefs, history, annotation model, stitcher, record math
Sources/Snapper/    app: Capture/, Annotate/, Record/, Tools/ (OCR, pin, scrolling), UI/, App/ (hotkeys, CLI)
Tests/SnapKitTests/ unit tests
scripts/            build-app.sh, make-signing-identity.sh, make-icon.swift
docs/               prd.md, security.md
```

## Status

Personal tool, not notarized. M1–M4 (capture, annotate, recording, OCR / pin / scrolling / history / settings) done; integration polish ongoing. Scrolling capture can mis-stitch pages with animation or parallax; that's a limit of image matching.

Docs: [`docs/prd.md`](docs/prd.md), [`docs/security.md`](docs/security.md), [`HERMES.md`](HERMES.md).

Built by [Melvern Mogens](https://github.com/MelvernMogens).
