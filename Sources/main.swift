import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// Keycode for the ` / ~ key on an ANSI keyboard.
private let kTildeKeyCode: Int64 = Int64(kVK_ANSI_Grave) // 50

/// Tracks application focus history and performs the "jump back" switch.
final class AppSwitcher {
    static let shared = AppSwitcher()

    private var currentApp: NSRunningApplication?
    private var previousApp: NSRunningApplication?

    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?

    private var ownBundleID: String? { Bundle.main.bundleIdentifier }
    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    func start() {
        currentApp = NSWorkspace.shared.frontmostApplication
        setupStatusItem()
        observeAppActivation()

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

    // MARK: - Focus tracking

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        // Ignore our own (menu-bar) activation and repeats of the current app.
        if app.processIdentifier == ownPID { return }
        if let bid = app.bundleIdentifier, bid == ownBundleID { return }
        if app.processIdentifier == currentApp?.processIdentifier { return }

        previousApp = currentApp
        currentApp = app
    }

    /// Activate the previously focused application. Pressing the hotkey repeatedly
    /// toggles between the two most-recent apps (like releasing Cmd+Tab).
    func jumpBack() {
        guard let target = previousApp, !target.isTerminated else { return }
        target.activate(options: [.activateAllWindows])
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
