# AGENTS.md

DTerm is an Objective-C (ARC) Cocoa menu-bar/agent app: a global hotkey pops up a command-line panel over the frontmost window, with the working directory and selected files taken from that window. Deployment target is macOS 12.0.

## Toolchain constraint: no Xcode, UI is frozen nibs

This machine has only the Xcode **Command Line Tools**, not Xcode. `xcodebuild`, `ibtool` and `actool` all fail with "requires Xcode". `clang` + the macOS SDK compile the sources fine.

- `CompiledNibs/` holds the compiled nibs (`Base.lproj/MainMenu.nib`, `Base.lproj/Preferences.nib`, `Base.lproj/TermWindow.nib`, `RTFWindow.nib`). They were copied from the installed `/Applications/DTerm.app` release build `1.7.91-012c4bc`, which was built from a clean tree at commit `012c4bc`, so they match the `.xib` sources as of that commit. A build copies them into `DTerm.app/Contents/Resources/` in the same layout instead of compiling the xibs.
- **Do not edit `.xib` files.** Changes cannot be compiled here, so the xibs would silently drift from `CompiledNibs/`. Treat the xibs as read-only documentation of what the nibs contain (view hierarchy, outlets, bindings).
- **Implement all new UI changes in code**, not in Interface Builder files:
  - Adjust or add views to nib-loaded windows in `windowDidLoad` / `awakeFromNib` of the owning controller or view. Existing examples: `DTTermWindowController -windowDidLoad` swaps `resultsView` in for a placeholder and prunes `actionMenu`; `DTResultsView -awakeFromNib` restyles buttons.
  - Build new windows programmatically (an `NSWindowController` created with a window built in code), not with `initWithWindowNibName:`.
  - Add menu items to `NSApp.mainMenu` / `actionMenu` in code.
- **Keep nib-referenced names stable.** Nibs resolve names at load time, so renaming or removing any of these breaks loading or bindings at runtime, with no compile error:
  - classes (`DTAppController`, `DTTermWindowController`, `DTPrefsWindowController`, `DTPrefsAXController`, `DTResultsView`, `DTResultsTextView`, `DTTermWindowContentView`, `DTProgressCancelButton`, `DTAntialiasControllableTextField`, `RTFWindowController`, `SRRecorderControl`)
  - `IBOutlet` ivars/properties and `IBAction` selectors
  - bound key paths (e.g. `runs`, `command`, `workingDirectory`, `commandFieldEditor.isFirstResponder`, `resultsCommandFontSize`, `axAppTrusted`, `values.DT*` defaults keys)
  - `grep` the xibs to check before renaming.

## Commands

The `Makefile` builds with the Command Line Tools only (GNU Make 3.81, clang, plutil, codesign, hdiutil):

```sh
make                               # build/Release/DTerm.app (host architecture only, ad-hoc signed)
make build-universal               # build/Release/DTerm.app (universal arm64 + x86_64)
make dmg                           # build/Release/DTerm.dmg (app + /Applications symlink, no background/layout)
make dmg ARCHS="arm64 x86_64"      # universal DMG
make clean                         # rm -rf build
make CODESIGN_IDENTITY="Developer ID Application: …"   # real signing identity instead of ad-hoc
```

- **Architectures:** `ARCHS` defaults to `uname -m`. Objects go to `build/obj/<archs>/` (e.g. `build/obj/arm64-x86_64/`), and the binary is linked there and copied into the bundle on every build. This means switching between single-arch and universal builds never mixes stale objects.

- **Sources:** `.m` files are picked up automatically from `.`, `Utilities/`, `Term Window/` and `3rd party source/ShortcutRecorder/`. A new source directory needs its own static pattern rule. The Makefile explains why: Make 3.81 won't match plain pattern rules whose prerequisites contain spaces.
- **Resources:** listed explicitly in the `app` recipe, so a new resource file must be added there.
- **Version:** computed like the Xcode `Revision` target and written into the bundle's `Info.plist` with `plutil`.
- **Signing:** no hardened runtime or entitlements, matching the released app. Enabling the hardened runtime would need the `com.apple.security.automation.apple-events` entitlement for ScriptingBridge/System Events to keep working.
- **Sandbox:** `hdiutil` fails inside a sandbox with "Device not configured".

Syntax/type-check a single file (same include/prefix flags the Makefile uses):

```sh
clang -fsyntax-only -fobjc-arc -mmacosx-version-min=12.0 -include DTerm_Prefix.pch \
  -I Utilities -I "Term Window" -I ScriptingBridge -I "3rd party source/ShortcutRecorder" -I . \
  DTAppController.m
```

Deprecation warnings are expected. Their text contains `...:error:]`, so match `^[^ ]+:[0-9]+:[0-9]+: error:` when grepping for real errors.

`./build.sh [--clean] [--no-code-sign] [--code-sign-identity NAME] [--with-dmg]` is the original Xcode-based release build (`--with-dmg` needs `brew install create-dmg`). It **does not work without Xcode**; use `make` instead.

Tests: the `Tests` target (XCTest, `Tests/ShellUtilitiesTests.m`, which covers `DTShellUtilities` path escaping and shell-word parsing) needs Xcode. The Command Line Tools don't ship XCTest. With Xcode it would be `xcodebuild -project DTerm.xcodeproj -scheme DTerm test [-only-testing:Tests/ShellUtilitiesTests/testPathEscaping]`. Everything else is verified manually against `Checklist for release.txt`.

## Architecture

- **Activation (`DTAppController`)**: an agent app (`LSUIElement`). The optional dock icon is enabled at launch via `TransformProcessType`. A global hotkey is registered with the Carbon `RegisterEventHotKey`. It uses ShortcutRecorder's `KeyCombo` (vendored in `3rd party source/`) and is persisted in the `DTHotKey` default. `-hotkeyPressed` works out the context from the frontmost app:
  - Finder and Path Finder: ScriptingBridge, using the pre-generated headers in `ScriptingBridge/`. They provide the selection, the target folder and the window bounds.
  - Any other app: System Events AX attributes (`AXFocusedWindow`, `AXDocument`). This requires Accessibility trust.
  - Working directory fallback: walk up from the selected file looking for marker entries (`DTWorkdirUpfindEntries`, e.g. `.git`, `Makefile`), then the file's directory, then `$HOME`.
  - AppleScript window coordinates are flipped into Cocoa screen coordinates before use.
- **Term window (`DTTermWindowController`, `TermWindow.nib`)**: an `NSPanel` positioned over the front window (70% of its width, min 640, capped relative to 1680). It hides on resign-key.
  - Each executed command becomes a `DTRunManager` added to `runsController`, an `NSArrayController` bound to `runs`. Previous/next result navigation is the array controller's `selectPrevious:`/`selectNext:`. `DTResultsToKeep` trims finished runs on deactivate.
  - "Execute in Terminal" (⌘↩) uses agterm when it is installed (`com.umputun.agterm`), otherwise Terminal via ScriptingBridge.
    - agterm is driven off the main thread by the `agtermctl` bundled in `agterm.app/Contents/MacOS`, which is launched with `--json`:
      - `window select active` raises (or reopens) the active window, retried while a freshly launched agterm starts up.
      - `session new --window … --cwd …` creates a selected session in that window.
      - `session type` types the command plus a newline, once `session text` shows a prompt.
    - agtermctl doesn't activate agterm itself, so DTerm activates it through `NSRunningApplication`.
- **Command field (`DTCommandFieldEditor`)**: a custom field editor returned from `windowWillReturnFieldEditor:toObject:`. Tab completion shells out to bash `compgen` (`-completionsForPartialWord:…` in the window controller). Shell quoting helpers live in `Utilities/DTShellUtilities`.
- **Command history**: `DTTermWindowController` keeps `commandHistory` (oldest first, at most 500, consecutive duplicates dropped, commands starting with a space not recorded), saved in the `DTCommandHistory` default. Text in the command field is replaced only through `-replaceCommandFieldText:`.
  - ↑/↓ (and ⌃P/⌃N): `DTCommandFieldEditor -moveUp:`/`-moveDown:` call `-historyPrevious`/`-historyNext`. While the Tab completion list is open, it consumes the arrow keys itself.
  - ⌃R: the "Search History…" item is added to `actionMenu` in `windowDidLoad`. It opens `DTHistorySearchController`, a borderless non-activating child panel built in code, with fzf-style fuzzy matching.
  - While that panel is key, `windowDidResignKey:` must not hide DTerm, so it returns early when `historySearch.isOpen`. The panel reports focus leaving the app through its completion block (`lostFocus`).
- **Command execution (`DTRunManager`)**:
  - Runs the command through the user's shell: the `ShellPath` default, else `$SHELL`, else `/bin/bash`. bash/sh/zsh get `-l -i -c`, other shells `-i -c`.
  - Exports `DTERM_SELECTED_FILES`. `TERM`, `TERM_PROGRAM` and `TERM_PROGRAM_VERSION` are set process-wide at launch.
  - Streams stdout/stderr asynchronously and parses ANSI escape sequences, BS and CR into an attributed `resultsStorage`, which `DTResultsTextView` displays through a binding to `runsController.selection.resultsStorage`.
  - Both `DTRunManager` and the completion task temporarily reset the effective GID around `-[NSTask launch]`, to work around the sticky accessibility egid.
- **Preferences (`DTPrefsWindowController`, `Preferences.nib`)**: panes for General, Accessibility (`DTPrefsAXController`) and Updates.
  - Almost entirely Cocoa bindings to `NSUserDefaultsController` `values.DT*` keys. Defaults are registered in `-applicationWillFinishLaunching:`.
  - Font/colour changes are observed via KVO in `DTTermWindowController` and pushed to every run. The font panel's `changeFont:` is handled in `DTAppController`.
  - Value transformers are registered by name in `+initialize`, because the nib refers to them by name.
- **URL scheme**: `dterm://prefs/{general,accessibility,updates}` opens the matching preference pane.
- **Vestigial integrations**: Sparkle is not linked, so the `sparkleUpdater` outlet is nil even though `Preferences.nib` still binds to it. Growl notifications are commented out (`TODO: re-add Growl support` in `DTRunManager`).

## Conventions

- `DTerm_Prefix.pch` imports Cocoa and Carbon into every file. It also defines `APP_DELEGATE` (the `DTAppController` app delegate) and `UnusedParameter(x)`, used to silence `-Wunused-parameter` under the project's `-Wall -Wextra`.
- New `NSUserDefaults` keys get an `NSString* const DT…Key` constant in `DTAppController.m` (exported in the header if used elsewhere) and a default in the `registerDefaults:` dictionary.
