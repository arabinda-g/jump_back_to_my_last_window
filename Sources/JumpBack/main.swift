import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// Keycode for the ` / ~ key on an ANSI keyboard.
private let kTildeKeyCode: Int64 = Int64(kVK_ANSI_Grave) // 50

/// UserDefaults key for whether the menu-bar icon is shown.
private let kShowMenuBarIconKey = "ShowMenuBarIcon"

/// Posted (cross-process) by a second launch to ask the running instance to
/// reveal its settings window. Used when the menu-bar icon is hidden and the
/// only way back in is to launch the app again.
private let kOpenSettingsNotification = Notification.Name("arabinda.me.jumpback.openSettings")

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
    private var settingsWindowController: SettingsWindowController?

    private var ownBundleID: String? { Bundle.main.bundleIdentifier }
    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    /// Whether the menu-bar icon is shown. Defaults to `true` on first launch.
    var showMenuBarIcon: Bool {
        get {
            if UserDefaults.standard.object(forKey: kShowMenuBarIconKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: kShowMenuBarIconKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kShowMenuBarIconKey)
            updateStatusItemVisibility()
        }
    }

    func start() {
        updateStatusItemVisibility()
        startWindowTracking()

        // If the icon starts hidden, there's no obvious entry point, so surface
        // the settings window once at launch.
        if !showMenuBarIcon { showSettings() }

        if ensureAccessibilityPermission() {
            installEventTap()
        } else {
            // Permission not granted yet. Poll until the user grants it, then install the tap.
            waitForAccessibilityThenInstall()
        }
    }

    // MARK: - Menu bar

    /// Create or tear down the status item to match `showMenuBarIcon`.
    private func updateStatusItemVisibility() {
        if showMenuBarIcon {
            if statusItem == nil { setupStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Settings window

    /// Show (creating if needed) the settings window and bring the app forward.
    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.syncFromSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        showSettings()
    }

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
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(openSettings),
                                keyEquivalent: ","))
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

// MARK: - Settings window

/// A small settings window: toggle the menu-bar icon and quit the app.
final class SettingsWindowController: NSWindowController {
    private var iconCheckbox: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jump Back Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Jump Back to My Last Window")
        title.font = .boldSystemFont(ofSize: 15)
        title.translatesAutoresizingMaskIntoConstraints = false

        let checkbox = NSButton(checkboxWithTitle: "Show menu-bar icon",
                                target: self,
                                action: #selector(toggleIcon(_:)))
        checkbox.state = AppSwitcher.shared.showMenuBarIcon ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        iconCheckbox = checkbox

        let hint = NSTextField(wrappingLabelWithString:
            "When the icon is hidden, launch Jump Back again to reopen this window.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let quit = NSButton(title: "Quit Jump Back", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.keyEquivalent = "q"
        quit.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(checkbox)
        content.addSubview(hint)
        content.addSubview(quit)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            checkbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            checkbox.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 6),

            quit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            quit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    @objc private func toggleIcon(_ sender: NSButton) {
        AppSwitcher.shared.showMenuBarIcon = (sender.state == .on)
    }

    /// Refresh the checkbox in case the setting changed elsewhere.
    func syncFromSettings() {
        iconCheckbox?.state = AppSwitcher.shared.showMenuBarIcon ? .on : .off
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
        // Single-instance guard: if another copy is already running, ask it to
        // reveal its settings window (the icon may be hidden) and then bow out.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    kOpenSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
        }

        // Listen for future launches asking us to open settings.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsNotification),
            name: kOpenSettingsNotification,
            object: nil)

        AppSwitcher.shared.start()
    }

    @objc private func handleOpenSettingsNotification() {
        AppSwitcher.shared.showSettings()
    }

    // Fires when the app is relaunched from Finder/Dock while already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppSwitcher.shared.showSettings()
        return true
    }
}
