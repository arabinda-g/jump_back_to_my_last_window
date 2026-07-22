# jump_back_to_my_last_window

A tiny native macOS menu-bar app. Press the **`` ` ``** (tilde) key to instantly switch
back to the previously focused application — across *any* app, like releasing Cmd+Tab.
Press it again to toggle back.

- Menu-bar icon only (no Dock icon, no window).
- Global hotkey: the bare **`` ` ``** key.
- Works system-wide against every application.

## Build

```sh
./build.sh            # debug build  -> build/JumpBack.app
./build.sh release    # optimized build
```

Requires the Xcode command-line tools (`swiftc`). No third-party dependencies.

## Run

```sh
open build/JumpBack.app
```

A ⤾ icon appears in the menu bar. Use its menu to open Accessibility settings or quit.

### Accessibility permission (required)

The global hotkey uses a `CGEventTap`, which macOS gates behind **Accessibility**
permission. On first launch you'll be prompted; grant it under:

**System Settings → Privacy & Security → Accessibility** → enable **JumpBack**.

The app polls once per second and activates the hotkey automatically the moment the
permission is granted (no relaunch needed). The build is ad-hoc code-signed with a
stable identity so the grant persists across rebuilds.

## Develop / debug in VSCode

- **Build:** `⌘⇧B` (runs the `build-debug` task).
- **Run:** Terminal → Run Task → `run` (or `open-app`).
- **Debug:** Run and Debug → **Debug JumpBack** (uses the
  [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb)
  extension, `type: lldb`). Install CodeLLDB if you don't have it.

## How it works

- `NSWorkspace.didActivateApplicationNotification` tracks the current and previous
  frontmost apps.
- A session-level `CGEventTap` watches for the `` ` `` keycode (`kVK_ANSI_Grave`, 50).
  A **bare** press is swallowed and triggers the switch; `Shift+`` ` `` (~) and
  `Cmd+`` ` `` (window cycling) are passed through untouched.
- `previousApp.activate(...)` brings the last app (and its focused window) forward.

> Note: because a bare `` ` `` press is intercepted app-wide, you can't type a literal
> backtick while JumpBack is running. The tilde character (`Shift+`` ` ``) still works.
> Quit from the menu bar to restore normal `` ` `` typing.
