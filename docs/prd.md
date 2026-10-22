# PRD — Snapper

Status: draft. Living document — correct it when reality disagrees, do not let it rot.

## 1. The problem
Melvern wants CleanShot X's workflow: instant area capture, a thumbnail to drag or annotate, quick recordings. He wants it as his own app instead of a paid closed one.

## 2. What we are building
A menu-bar app covering CleanShot X's daily-use features with native frameworks only.

## 3. Who it is for
Melvern, on his MacBook (macOS 27, Retina 1440×900 pt). A single user.

## 4. What "done" means for the MVP
Each of these works from the installed app via hotkey or menu, end to end, on the real screen:
area capture → Quick Access → annotate → copy/save; window capture with shadow; record MP4 and GIF; OCR to clipboard;
pin; scrolling capture; history browse; settings that persist.

## 5. Scope
### In
Capture modes (area, window, fullscreen, previous area, self-timer), freeze-frame overlay with loupe, Quick Access, Annotate,
pin, OCR, scrolling capture, MP4/GIF recording with click rings, history, settings, hotkeys.

### Out (deliberately, for now)
Cloud upload/share links, video trimmer/editor, webcam overlay, keystroke overlay, multi-language UI, notarization.

## 6. What not to oversell
- You can say "a CleanShot-style capture and annotate tool for my Mac, with no subscription and no cloud."
- You cannot say "full CleanShot X replacement". There is no cloud sharing and no video editing. Scrolling capture can mis-stitch animated pages.

## 7. Constraints that shape the build
- There are no third-party dependencies and no Xcode project.
- Ad-hoc signing means the Screen Recording grant can reset on a rebuild.
- Every feature must be verifiable headlessly (`--cli` commands), because agents cannot click.

## 8. Parts inventory
Overlay/selection · ScreenCaptureKit grabber · output pipeline (file/clipboard/sound) · Quick Access · history store + window ·
annotate (tools, undo, flatten, background) · recorder (SCStream, writer, GIF, HUD, click rings) · OCR · pin windows ·
scroll stitcher · settings · hotkeys · app bundle + icon.

## 9. Milestones
See HERMES.md (M1 core → M2 annotate → M3 recording → M4 tools → M5 polish). The capture core went first because
everything else consumes its `CaptureItem` and coordinate conventions.

## 10. Backlog
Video trimmer, webcam bubble, keystroke overlay, customizable shortcuts recorder UI, cloud upload (Supabase/S3 own bucket),
"capture all screens" stitched mode, annotate presets.

Per-milestone model/effort guidance lives in `HERMES.md`, not here.

## 11. Open questions
- Should Snapper take over ⌘⇧3/4/5 by default? Currently it is opt-in (⌥⌘ digits by default), because hijacking system keys is surprising.
- History cap is 300 entries and recordings can be large. A size-based cap may be needed.
