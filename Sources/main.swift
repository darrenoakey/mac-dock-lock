import Cocoa
import ServiceManagement

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var enabledMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var launchMenuItem: NSMenuItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityTimer: Timer?
    private var isEnabled = true
    private var hasShownMisplacedAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        registerNotifications()
        ensureAccessibilityAndStartTap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateDockStatus()
        }
    }

    // MARK: - Accessibility

    private func ensureAccessibilityAndStartTap() {
        if AXIsProcessTrusted() {
            startEventTap()
            return
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityTimer = nil
                self?.startEventTap()
                self?.updateDockStatus()
            }
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self

        enabledMenuItem = NSMenuItem(
            title: "Lock Dock to Main Display",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: "")
        enabledMenuItem.target = self
        enabledMenuItem.state = .on
        menu.addItem(enabledMenuItem)

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        launchMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: "")
        launchMenuItem.target = self
        updateLaunchAtLoginState()
        menu.addItem(launchMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit DockLock",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = isEnabled ? "lock.fill" : "lock.open.fill"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "DockLock") {
            image.isTemplate = true
            button.image = image
        }
    }

    private func updateLaunchAtLoginState() {
        launchMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Menu Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off
        updateIcon()
        if isEnabled {
            startEventTap()
        } else {
            stopEventTap()
        }
        updateDockStatus()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            updateLaunchAtLoginState()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not configure Launch at Login"
            alert.informativeText = """
                \(error.localizedDescription)

                Ensure DockLock.app is installed in /Applications.
                """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - CGEventTap (Prevention)
    //
    // Blocks mouseMoved events when the cursor enters a 10px trigger zone on
    // the Dock edge of any non-main display. This prevents macOS from migrating
    // the Dock — the cursor simply stops at the zone boundary, like hitting a
    // screen edge. No cursor warping or manipulation.
    //
    // Requires Accessibility permission (System Settings > Privacy > Accessibility).

    private func startEventTap() {
        guard isEnabled, eventTap == nil, AXIsProcessTrusted() else { return }

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return app.handleMouseEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else { return }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it due to timeout or user input
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        if isInDockTriggerZone(event.location) {
            return nil // Drop event — cursor stops at zone boundary
        }
        return Unmanaged.passUnretained(event)
    }

    /// Returns true if the point is in the Dock trigger zone of any non-main display.
    /// The trigger zone is a 10px strip on the Dock edge (bottom/left/right) where
    /// hovering causes macOS to migrate the Dock to that display.
    private func isInDockTriggerZone(_ point: CGPoint) -> Bool {
        let mainID = CGMainDisplayID()
        let orientation = dockOrientation()
        let triggerSize: CGFloat = 10

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)

        for i in 0..<Int(count) {
            let id = ids[i]
            if id == mainID { continue }

            let b = CGDisplayBounds(id)
            let zone: CGRect
            switch orientation {
            case "left":
                zone = CGRect(x: b.minX, y: b.minY, width: triggerSize, height: b.height)
            case "right":
                zone = CGRect(x: b.maxX - triggerSize, y: b.minY, width: triggerSize, height: b.height)
            default:
                zone = CGRect(x: b.minX, y: b.maxY - triggerSize, width: b.width, height: triggerSize)
            }
            if zone.contains(point) { return true }
        }
        return false
    }

    // MARK: - Notifications (Status Updates)

    private func registerNotifications() {
        // Screen geometry changed (fires when Dock migrates between displays)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScreenChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Dock preferences changed (orientation, autohide, etc.)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onDockChange),
            name: NSNotification.Name("com.apple.dock.prefchanged"), object: nil)

        // Active display changed (undocumented; used by yabai & Hammerspoon)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onActiveDisplayChange),
            name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"), object: nil)

        // Dock process restarted
        NotificationCenter.default.addObserver(
            self, selector: #selector(onDockRestart),
            name: NSNotification.Name("NSApplicationDockDidRestartNotification"), object: nil)

        // System woke from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func onScreenChange(_ n: Notification) { updateDockStatus() }
    @objc private func onDockChange(_ n: Notification) { updateDockStatus() }
    @objc private func onActiveDisplayChange(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateDockStatus()
        }
    }
    @objc private func onDockRestart(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateDockStatus()
        }
    }
    @objc private func onWake(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.updateDockStatus()
        }
    }

    // MARK: - Detection & Status

    private func dockOrientation() -> String {
        UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Finds which screen currently hosts the Dock by comparing visibleFrame gaps.
    /// The screen with the Dock has a larger inset on the Dock's edge.
    /// No special permissions required — uses only public NSScreen API.
    private func detectDockScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return screens.first }

        let orientation = dockOrientation()
        var best: NSScreen?
        var maxGap: CGFloat = 0

        for screen in screens {
            let f = screen.frame
            let v = screen.visibleFrame
            let gap: CGFloat
            switch orientation {
            case "left":  gap = v.minX - f.minX
            case "right": gap = f.maxX - v.maxX
            default:      gap = v.minY - f.minY
            }
            if gap > maxGap {
                maxGap = gap
                best = screen
            }
        }
        return maxGap > 2 ? best : nil
    }

    private func updateDockStatus() {
        if !AXIsProcessTrusted() {
            statusMenuItem.title = "Needs Accessibility permission"
            return
        }
        guard NSScreen.screens.count > 1 else {
            statusMenuItem.title = "Single display"
            return
        }
        guard let dockScreen = detectDockScreen() else {
            statusMenuItem.title = "Dock position: unknown"
            return
        }

        let onMain = displayID(for: dockScreen) == CGMainDisplayID()
        if onMain {
            statusMenuItem.title = "Dock: locked to main display"
            hasShownMisplacedAlert = false
        } else {
            statusMenuItem.title = "Dock: on \(dockScreen.localizedName)"
            if !hasShownMisplacedAlert {
                hasShownMisplacedAlert = true
                let alert = NSAlert()
                alert.messageText = "Dock is on \(dockScreen.localizedName)"
                alert.informativeText = "Move your cursor to the bottom edge of the main display to bring the Dock back. DockLock will prevent it from moving away again."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateDockStatus()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
