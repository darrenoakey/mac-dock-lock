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
    private var backupTimer: Timer?
    private var isEnabled = true
    private var isRelocating = false
    private var relocationAttempts = 0
    private let syntheticMarker: Int64 = 0x444F434B // "DOCK"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        registerNotifications()
        ensureAccessibilityAndStartTap()
        startBackupTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkAndCorrectDock()
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
                self?.checkAndCorrectDock()
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
            startBackupTimer()
            checkAndCorrectDock()
        } else {
            stopEventTap()
            backupTimer?.invalidate()
            backupTimer = nil
        }
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
    // Blocks mouseMoved events in the Dock trigger zone of non-main displays.
    // During relocation, blocks ALL real events but passes synthetic ones
    // (identified by syntheticMarker in eventSourceUserData).

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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        // During relocation: pass our synthetic events, block real ones
        if isRelocating {
            if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }

        // Normal: block events in trigger zones on non-main displays
        if isInDockTriggerZone(event.location) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

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

    // MARK: - Dock Correction (Synthetic HID Events)
    //
    // Uses DockAnchor's proven technique: hide cursor, send synthetic mouse
    // events via .cghidEventTap with .hidSystemState source to simulate cursor
    // presence at the main display's Dock edge. Events are marked with
    // syntheticMarker so the event tap lets them through while blocking real
    // mouse input. The cursor is hidden during the ~0.7s operation and restored
    // to its original position — invisible to the user.

    private func relocateDock() {
        guard !isRelocating, AXIsProcessTrusted() else { return }
        guard relocationAttempts < 5 else {
            relocationAttempts = 0
            return
        }
        isRelocating = true
        relocationAttempts += 1

        let savedPos = CGEvent(source: nil)?.location ?? .zero
        NSCursor.hide()

        DispatchQueue.global(qos: .userInteractive).async { [self] in
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            let orientation = dockOrientation()

            // Target: Dock edge of main display. Approach: 50px before the edge.
            let target: CGPoint
            let approach: CGPoint
            switch orientation {
            case "left":
                target = CGPoint(x: mainBounds.minX, y: mainBounds.midY)
                approach = CGPoint(x: mainBounds.minX + 50, y: mainBounds.midY)
            case "right":
                target = CGPoint(x: mainBounds.maxX - 1, y: mainBounds.midY)
                approach = CGPoint(x: mainBounds.maxX - 51, y: mainBounds.midY)
            default:
                target = CGPoint(x: mainBounds.midX, y: mainBounds.maxY - 1)
                approach = CGPoint(x: mainBounds.midX, y: mainBounds.maxY - 51)
            }

            let source = CGEventSource(stateID: .hidSystemState)

            // Move to approach point
            CGWarpMouseCursorPosition(approach)
            usleep(30_000)

            // Progressive move from approach to target (8 steps)
            for i in 0..<8 {
                let t = CGFloat(i + 1) / 8.0
                let pos = CGPoint(
                    x: approach.x + (target.x - approach.x) * t,
                    y: approach.y + (target.y - approach.y) * t
                )
                CGWarpMouseCursorPosition(pos)
                if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                    mouseCursorPosition: pos, mouseButton: .left) {
                    ev.setIntegerValueField(.eventSourceUserData, value: self.syntheticMarker)
                    ev.post(tap: .cghidEventTap)
                }
                usleep(30_000)
            }

            // Hold at target edge (10 events to trigger Dock migration)
            for _ in 0..<10 {
                CGWarpMouseCursorPosition(target)
                if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                    mouseCursorPosition: target, mouseButton: .left) {
                    ev.setIntegerValueField(.eventSourceUserData, value: self.syntheticMarker)
                    ev.post(tap: .cghidEventTap)
                }
                usleep(80_000)
            }

            // Restore cursor on main thread
            DispatchQueue.main.async { [self] in
                CGWarpMouseCursorPosition(savedPos)
                NSCursor.unhide()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.isRelocating = false
                    self?.checkAndCorrectDock()
                }
            }
        }
    }

    // MARK: - Check & Correct

    private func checkAndCorrectDock() {
        guard isEnabled, !isRelocating else { return }
        guard NSScreen.screens.count > 1 else {
            updateStatusText()
            return
        }

        guard let dockScreen = detectDockScreen() else {
            updateStatusText()
            return
        }

        let onMain = displayID(for: dockScreen) == CGMainDisplayID()
        if onMain {
            relocationAttempts = 0
            updateStatusText()
        } else {
            updateStatusText()
            relocateDock()
        }
    }

    private func updateStatusText() {
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
        statusMenuItem.title = onMain ? "Dock: locked to main display" : "Dock: on \(dockScreen.localizedName)"
    }

    // MARK: - Backup Timer (catches edge cases notifications miss)

    private func startBackupTimer() {
        backupTimer?.invalidate()
        backupTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkAndCorrectDock()
        }
    }

    // MARK: - Notifications

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScreenChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onDockChange),
            name: NSNotification.Name("com.apple.dock.prefchanged"), object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onActiveDisplayChange),
            name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"), object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(onDockRestart),
            name: NSNotification.Name("NSApplicationDockDidRestartNotification"), object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func onScreenChange(_ n: Notification) { checkAndCorrectDock() }
    @objc private func onDockChange(_ n: Notification) { checkAndCorrectDock() }
    @objc private func onActiveDisplayChange(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkAndCorrectDock()
        }
    }
    @objc private func onDockRestart(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkAndCorrectDock()
        }
    }
    @objc private func onWake(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkAndCorrectDock()
        }
    }

    // MARK: - Detection

    private func dockOrientation() -> String {
        UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

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
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateStatusText()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
