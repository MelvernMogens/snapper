# Snapper

A native macOS menu-bar app for screenshots, annotation and screen recording. It is a personal CleanShot X replacement.

It exists because CleanShot X is paid per-major and closed. Everything it does day to day is
ScreenCaptureKit + Vision + AppKit, which ship with macOS. Snapper is ~one Swift package with zero dependencies.

---

## How it works

```
hotkey / menu ──► ScreenGrabber (ScreenCaptureKit, own windows excluded)
                     │ freeze every display
                     ▼
              Overlay (dim + loupe + crosshair; Space = window mode)
                     │ selection in AppKit global points
                     ▼
              Capture.crop  ──► Output.finish ──► file (Desktop) + clipboard + History copy + sound
                                                     │
                                                     ▼
                                    Quick Access card ─► Annotate · Pin · Copy · Save · drag-out
Recording: SCStream(sourceRect) ─► AVAssetWriter MP4 ─► (GIF: ImageIO) ─► Output.finishMovie
```

## What this does and does not promise
- It **does** do area/window/fullscreen/previous-area/self-timer capture, annotation, OCR, pinning, scrolling capture, MP4/GIF recording and history.
- It **does not** do cloud upload/share links, video trimming/editing, webcam overlay, or keystroke display.
- Scrolling capture stitches by image matching. Pages with animated content or parallax can mis-stitch. That is a limit of the technique, not a bug to promise away.
- It is ad-hoc signed, not notarized. It is for this Mac only.

## Stack
| Part | Choice |
|---|---|
| Language / build | Swift 6, SwiftPM (no Xcode project) |
| Capture | ScreenCaptureKit (SCScreenshotManager, SCStream) |
| Video / GIF | AVAssetWriter H.264, ImageIO GIF |
| OCR | Vision `VNRecognizeTextRequest` |
| Hotkeys | Carbon `RegisterEventHotKey` (no Accessibility needed) |
| Logic + tests | `SnapKit` library + XCTest |

## Getting started
```bash
git clone git@github.com:MelvernMogens/snapper.git && cd snapper
swift test
scripts/build-app.sh --install     # builds, copies to /Applications, launches
```
On the first capture, macOS asks for Screen Recording permission. Grant it, then quit and reopen Snapper.

## Commands
| Command | What |
|---|---|
| `swift test` | Unit tests (geometry, naming, history, stitcher, annotation model) |
| `.build/debug/Snapper --help` | Headless verification commands |
| `scripts/build-app.sh --install` | Build + install the .app |

## Shortcuts
| Keys | Action |
|---|---|
| ⌥⌘3 / ⌥⌘4 / ⌥⌘5 | Fullscreen / Area / Window |
| ⌥⌘6 | Previous area |
| ⌥⌘7 | Record screen (press again to stop) |
| ⌥⌘8 | Capture text (OCR) |
| ⌥⌘9 / ⌥⌘0 | History / Scrolling capture |

Settings can also take over ⌘⇧3/4/5 once the macOS ones are switched off in Keyboard › Shortcuts › Screenshots.

## Gotcha: permission resets after rebuilding
An ad-hoc codesign produces a new signature each build, so macOS can treat a reinstalled Snapper as a new app.
If captures come back as wallpaper-only or fail, remove Snapper from Privacy & Security › Screen & System Audio Recording,
relaunch it, and grant access again.

## Roadmap
| # | Scope | Status |
|---|---|---|
| M1 | Capture core + Quick Access + history store | done |
| M2 | Annotate editor | in progress |
| M3 | MP4 / GIF recording | in progress |
| M4 | OCR, pin, scrolling capture, history UI, settings | in progress |
| M5 | Integration polish | todo |

## Docs
- [`docs/prd.md`](docs/prd.md): problem, scope, non-goals, open questions
- [`HERMES.md`](HERMES.md): working notes and conventions
