# Threat model — Snapper

Small attack surface: a local, single-user menu-bar app. It has no network, no accounts and no stored secrets.

## What we protect, and from whom

| Asset | Adversary | Why it matters |
|---|---|---|
| Captured pixels (may show passwords, chats, banking) | Anything that can read `~/Library/Application Support/Snapper/History` or the Desktop | History keeps a private copy of every capture until trimmed (300) or cleared |
| Screen Recording permission | Another process abusing a granted, ad-hoc-signed binary | The grant is tied to this binary; a swapped binary at the same path loses it on signature change |

## Current posture
- There is no network code at all. Nothing is uploaded.
- History files are plain PNG/MP4 in the user's Library, with the same protection as the Desktop.
- Blur/pixelate in Annotate is applied to the flattened pixels. The saved file does not contain the original pixels under the blur.

## Rules that must hold
- No networking APIs in the package (`grep -rn "URLSession\|NWConnection" Sources` must stay empty).
- The blur tool must modify output pixels. This is enforced by the annotation flatten unit test.
- Snapper's own overlay/HUD windows are excluded from every capture (ScreenGrabber own-pid filter).

## Accepted risks
- History is not encrypted at rest. FileVault covers the disk, and "Clear history" exists.
- It is not notarized, which is acceptable for a single-machine personal tool.
