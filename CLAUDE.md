# DockLock

macOS menu bar utility that keeps the Dock locked to the primary display.

## Build & Run

- `make run` — Build, bundle, sign, and launch
- `make install` — Install to /Applications (required for Launch at Login)
- `make clean` — Clean build artifacts

## Architecture

- Single-file Swift app (`Sources/main.swift`), macOS 13+
- NSApplication with `.accessory` activation policy (menu bar only, no Dock icon)
- .app bundle with `LSUIElement=true`, ad-hoc signed

### Prevention (not correction)

Uses CGEventTap (`.cgSessionEventTap`, `.defaultTap`) to block `mouseMoved` events in a 10px trigger zone on the Dock edge of non-main displays. The cursor stops at the zone boundary — identical to hitting a screen edge. No cursor warping.

**Why not correction?**
- `killall Dock` does NOT move the Dock back — it returns to the same display after restart
- `CGWarpMouseCursorPosition` + synthetic CGEvents do NOT trigger Dock migration — WindowServer requires real HID input
- No public API, `defaults write` key, or CoreDock/SkyLight function controls which display hosts the Dock

### Detection

`NSScreen.visibleFrame` comparison: the screen hosting the Dock has a larger inset on the Dock's edge (bottom/left/right). Works even with auto-hide (~4px tracking area). No permissions required.

### Notifications (5 event sources)

1. `NSApplication.didChangeScreenParametersNotification` — screen geometry changes
2. `com.apple.dock.prefchanged` — Dock preference changes (distributed notification)
3. `NSWorkspaceActiveDisplayDidChangeNotification` — active display changed (undocumented, used by yabai/Hammerspoon)
4. `NSApplicationDockDidRestartNotification` — Dock process restart
5. `NSWorkspace.didWakeNotification` — wake from sleep

## Permissions

- **Accessibility** (System Settings > Privacy > Accessibility): Required for CGEventTap with `.defaultTap` (blocking mode). App polls for permission grant on startup.
- **Launch at Login**: Requires app installed in /Applications with valid bundle ID (`com.darrenoakey.DockLock`)
