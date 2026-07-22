import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// Keycode for the ` / ~ key on an ANSI keyboard.
private let kTildeKeyCode: Int64 = Int64(kVK_ANSI_Grave) // 50

/// A focused window we've seen, identified by its owning process and its
/// Accessibility element. Two references to the same on-screen window compare
/// equal via `CFEqual` on the elements.
private struct WindowRef {
    let pid: pid_t
    let element: AXUIElement
}

/// Tracks *window* focus history (across all apps) and performs the "jump
/// back" switch to the most-recently focused window that isn't the current one.
final class AppSwitcher {
    static let shared = AppSwitcher()

    /// Most-recently-used stack of focused windows. `windowHistory[0]` is the
    /// window focused right now; `[1]` is the one to jump back to.
    private var windowHistory: [WindowRef] = []
    private var appElementCache: [pid_t: AXUIElement] = [:]
    private var pollTimer: Timer?

    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?

    private var ownBundleID: String? { Bundle.main.bundleIdentifier }
    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    func start() {
        setupStatusItem()
        startWindowTracking()

        if ensureAccessibilityPermission() {
            installEventTap()
        } else {
            // Permission not granted yet. Poll until the user grants it, then install the tap.
            waitForAccessibilityThenInstall()
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = menuBarImage() {
                image.isTemplate = true // adapt to light/dark menu bar automatically
                button.image = image
            } else {
                button.title = "⤾"
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Jump Back to My Last Window", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let statusLine = NSMenuItem(title: "Hotkey: ` (tilde key)", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(NSMenuItem(title: "Open Accessibility Settings…",
                                action: #selector(openAccessibilitySettings),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = menuItem.action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        }

        item.menu = menu
        statusItem = item
    }

    /// The custom menu-bar glyph, bundled as a template PNG (with @2x). Falls
    /// back to the matching SF Symbol if the resource is missing.
    private func menuBarImage() -> NSImage? {
        if let image = NSImage(named: NSImage.Name("menubarTemplate")) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "arrow.uturn.backward.circle",
                       accessibilityDescription: "Jump Back")
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Window focus tracking

    /// macOS exposes no window-focus history, so we sample the frontmost app's
    /// focused window a few times a second and maintain our own MRU stack.
    /// Sampling the *frontmost app's focused window* captures both app switches
    /// (frontmost app changes) and same-app window switches (focused window
    /// changes while the app stays frontmost).
    private func startWindowTracking() {
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.sampleFocusedWindow()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func appElement(for pid: pid_t) -> AXUIElement {
        if let cached = appElementCache[pid] { return cached }
        let element = AXUIElementCreateApplication(pid)
        appElementCache[pid] = element
        return element
    }

    /// The currently focused (or, failing that, main) window of an app element.
    private func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    private func sampleFocusedWindow() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        // Ignore our own menu-bar process so our status menu never enters history.
        if pid == ownPID { return }
        if let bid = front.bundleIdentifier, bid == ownBundleID { return }

        guard let window = focusedWindow(of: appElement(for: pid)) else { return }
        record(WindowRef(pid: pid, element: window))
    }

    /// Push `ref` to the top of the MRU stack if it isn't already current.
    private func record(_ ref: WindowRef) {
        if let current = windowHistory.first, CFEqual(current.element, ref.element) {
            return // no change
        }
        windowHistory.removeAll { CFEqual($0.element, ref.element) }
        windowHistory.insert(ref, at: 0)
        pruneHistory()
    }

    /// Drop windows whose app has quit, and cap the stack size.
    private func pruneHistory() {
        let alive = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        windowHistory.removeAll { !alive.contains($0.pid) }
        if windowHistory.count > 24 { windowHistory.removeLast(windowHistory.count - 24) }
    }

    /// Raise and focus the most-recently-used window that isn't the current
    /// one. Pressing the hotkey repeatedly toggles between the two most-recent
    /// windows (like releasing Cmd+Tab, but window-level and cross-app).
    func jumpBack() {
        pruneHistory()
        // Try candidates from most- to least-recent, skipping the current window.
        for candidate in windowHistory.dropFirst() where focus(candidate) {
            // Reflect the switch immediately so a rapid second press toggles back,
            // without waiting for the next poll to update the stack.
            windowHistory.removeAll { CFEqual($0.element, candidate.element) }
            windowHistory.insert(candidate, at: 0)
            return
        }
    }

    /// Bring a specific window to the front: activate its app, un-minimize and
    /// raise the window, and make it the app's focused window.
    @discardableResult
    private func focus(_ ref: WindowRef) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: ref.pid), !app.isTerminated else {
            return false
        }
        // Bail if the element has gone stale (window closed).
        if AXUIElementPerformAction(ref.element, kAXRaiseAction as CFString) == .invalidUIElement {
            return false
        }
        AXUIElementSetAttributeValue(ref.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(ref.element, kAXRaiseAction as CFString)

        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementSetAttributeValue(appElement(for: ref.pid), kAXFocusedWindowAttribute as CFString, ref.element)
        return true
    }

    // MARK: - Global hotkey via event tap

    private func installEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            // The tap may be disabled by the system (timeout / user input); re-enable it.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = AppSwitcher.shared.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else { return Unmanaged.passUnretained(event) }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == kTildeKeyCode else { return Unmanaged.passUnretained(event) }

            // Only fire for a bare press. Keep Shift+` (~), Cmd+` (window cycling), etc. working.
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            if event.flags.isDisjoint(with: modifiers) {
                DispatchQueue.main.async { AppSwitcher.shared.jumpBack() }
                return nil // swallow the event so the backtick isn't typed
            }

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: nil
        ) else {
            NSLog("JumpBack: failed to create event tap (Accessibility permission required).")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("JumpBack: event tap installed. Hotkey ` is active.")
    }

    // MARK: - Accessibility permission

    @discardableResult
    private func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func waitForAccessibilityThenInstall() {
        NSLog("JumpBack: waiting for Accessibility permission…")
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.installEventTap()
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon, no window

let delegate = AppDelegate()
app.delegate = delegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSwitcher.shared.start()
    }
}
