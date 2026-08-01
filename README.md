# jump_back_to_my_last_window

A tiny native macOS menu-bar app. Press the **`` ` ``** (tilde) key to instantly switch
back to the previously focused application — across *any* app, like releasing Cmd+Tab.
Press it again to toggle back.

- Menu-bar icon only (no Dock icon, no window).
- Global hotkey: the bare **`` ` ``** key.
- Works system-wide against every application.

## Install

Download the latest `JumpBack-<version>.dmg` (or the `.zip`) from the
[Releases page](https://github.com/arabinda-g/jump_back_to_my_last_window/releases/latest),
open it, and drag **JumpBack.app** into **Applications**. Universal binary
(Apple Silicon + Intel), macOS 13 or later.

The app is signed with a self-signed local certificate, **not** a Developer ID, so it
isn't notarized and Gatekeeper will block it on first open. Either right-click the app
→ **Open** → **Open**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/JumpBack.app
```

Then grant Accessibility permission (see below) — the hotkey does not work without it.

## Build

A Swift Package Manager project (`Package.swift`). Build the raw executable with
`swift build`, or assemble the full `.app` bundle with the build script:

```sh
./build.sh                      # debug build  -> build/JumpBack.app
./build.sh release              # optimized build, host architecture
./build.sh release universal    # optimized fat arm64 + x86_64 build (release artifacts)
```

Requires the Xcode command-line tools (`swift`). No third-party dependencies.

### Icon

The app icon (`Resources/AppIcon.icns`) and the menu-bar template glyph
(`Resources/menubarTemplate*.png`) are checked in and copied into the bundle by
`build.sh`. To regenerate them (requires Python + Pillow):

```sh
python3 tools/make_icon.py --out Resources
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset
```

## Run

```sh
open build/JumpBack.app
```

A ⤾ icon appears in the menu bar. Use its menu to open Accessibility settings, open
**Settings…**, or quit.

### Settings

- **Show menu-bar icon** — hide the ⤾ glyph to run completely invisibly. With the icon
  hidden, launching Jump Back again reopens the settings window.
- **Launch at login** — registers the app with macOS (`SMAppService`, listed under
  **System Settings → General → Login Items**). A login launch starts Jump Back
  *silently*: no settings window and no permission prompt, just the hotkey running in
  the background. Launching it yourself still opens the window as usual.

### Accessibility permission (required)

The global hotkey uses a `CGEventTap`, which macOS gates behind **Accessibility**
permission. On first launch you'll be prompted; grant it under:

**System Settings → Privacy & Security → Accessibility** → enable **JumpBack**.

The app polls once per second and activates the hotkey automatically the moment the
permission is granted (no relaunch needed). Builds are signed with a stable code-signing
identity rather than ad-hoc, so the grant survives rebuilds and upgrades instead of being
revoked every time the binary changes.

## Develop / debug in VSCode / Cursor

- **Build:** `⌘⇧B` (runs the `Build JumpBack (swift)` task).
- **Run:** Terminal → Run Task → `Run JumpBack.app`.
- **Debug:** Run and Debug → **Debug JumpBack (.app)**. This uses the `lldb-dap`
  extension (`llvm-vs-code-extensions.lldb-dap`); the adapter path is pinned to
  Xcode's `lldb-dap` in [.vscode/settings.json](.vscode/settings.json). A
  **Debug JumpBack (CodeLLDB)** config is also provided as a self-contained fallback
  (needs the `vadimcn.vscode-lldb` extension).

> Reload the editor window (`Developer: Reload Window`) after installing a debug
> extension so the new debug type is recognized.

## How it works

- `NSWorkspace.didActivateApplicationNotification` tracks the current and previous
  frontmost apps.
- A session-level `CGEventTap` watches for the `` ` `` keycode (`kVK_ANSI_Grave`, 50).
  A **bare** press is swallowed and triggers the switch; `Shift+`` ` `` (~) and
  `Cmd+`` ` `` (window cycling) are passed through untouched.
- `previousApp.activate(...)` brings the last app (and its focused window) forward.
- Login launches are told apart from user launches by the `keyAELaunchedAsLogInItem`
  flag macOS sets on the open-application Apple event (read in
  `applicationDidFinishLaunching` — the event isn't dispatched yet in
  `applicationWillFinishLaunching`). That flag is what keeps a login start silent.

> Note: because a bare `` ` `` press is intercepted app-wide, you can't type a literal
> backtick while JumpBack is running. The tilde character (`Shift+`` ` ``) still works.
> Quit from the menu bar to restore normal `` ` `` typing.
