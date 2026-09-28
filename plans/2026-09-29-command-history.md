# Command history in DTerm: ↑ / ↓ navigation + Ctrl-R fuzzy search

## Context
The user wants shell-like command history in the DTerm command field:
1. **↑ / ↓** step to the previous or next command in history.
2. **Ctrl-R** opens a search panel: a text box with a list of matching history entries below it.
   - The list updates as you type.
   - ↑ and ↓ move through the list.
   - Enter puts the chosen command into the command field **without running it**.
   - Esc closes the panel and changes nothing.

So far they asked only how feasible and how hard this is. This plan records the findings and how it would be built.

**How hard**
- **↑ / ↓: easy.** About 60 lines across 3 files, no interface-file changes.
- **Ctrl-R: moderate.** About 250 lines, mostly one new class, plus one menu item. The only tricky part is keyboard focus: DTerm hides itself as soon as its window loses focus (details in Part 2).

## Relevant existing code
- `Term Window/DTCommandFieldEditor.m`: the text editor behind the command field (an `NSTextView` subclass). It already takes over a key the same way we'd need to, in `insertTab:` (`:36`).
- `Term Window/DTTermWindowController.m`:
  - `windowWillReturnFieldEditor:` (`:65`) supplies that editor.
  - `setCommand:` (`:78`) keeps the field and its binding in sync.
  - `activateWithWorkingDirectory:…` (`:91`) shows the window.
  - `deactivate` (`:137`) hides the window and cuts `runs` down to the "results to keep" setting.
  - `windowDidResignKey:` (`:169`) calls `deactivate`.
  - `pullCommandFromResults:` (`:205`) replaces the field's text by selecting everything and calling `insertText:`.
  - `executeCommand:` (`:216`) runs a command.
- `Base.lproj/TermWindow.xib`:
  - The window is a **non-activating HUD `NSPanel`** (`:24-25`) that can shrink to **92pt tall** (`:29`).
  - The action menu (`:56-150`) contains items with keyboard shortcuts that the popup button handles, e.g. "Insert Selected Items" ⌘⇧V.
- `DTAppController.h`: preference keys `DTFontNameKey`, `DTFontSizeKey` and `DTResultsToKeepKey`, so the list can use the user's terminal font.

---

## Part 1: shared history store and ↑ / ↓

**`Term Window/DTTermWindowController.h/.m`**
- Add `commandHistory`, a list of command strings with the oldest first. Don't use `runs` for this: it gets cut down to at most 100 entries, holds each command's full output, and is lost when the app quits.
- In `executeCommand:`, add `self.command` to the history unless it's identical to the last entry. Cap the list at about 500 and reset the history position.
- Optional: save and load the history under a new preference key, `DTCommandHistory`, declared next to the existing keys in `DTAppController.h/.m`.
- Take the "select all + `insertText:`" code out of `pullCommandFromResults:` and turn it into a helper, `-replaceCommandFieldText:(NSString*)text`, that also moves the cursor to the end. `pullCommandFromResults:`, ↑/↓ and Ctrl-R all use it.
- Add `historyIndex` (the position in the history) and `historyDraft` (what the user had typed), and methods `-historyPrevious` / `-historyNext`:
  - The first ↑ saves the current text as the draft.
  - ↓ past the newest entry puts the draft back.
  - Reset the position in `activateWithWorkingDirectory:`.

**`Term Window/DTCommandFieldEditor.m`**
- Override `moveUp:` to call `[controller historyPrevious]` and `moveDown:` to call `[controller historyNext]`.
- Ctrl-P and Ctrl-N go through the same two methods, so they work too. Shift+↑ and Shift+↓ (selecting text) are left alone.
- While the Tab-completion popup is open, it handles the arrow keys itself, so there's no conflict.

---

## Part 2: Ctrl-R fuzzy history search

### Constraints that shape the design
1. **The panel must not make DTerm hide itself.** `windowDidResignKey:` calls `deactivate`, so giving a second window keyboard focus would hide DTerm. We need a guard.
2. **The list can't fit inside the DTerm window.** The window can be only 92pt tall when there's no output, so the list goes in a separate borderless **child panel** placed just below the command field. A child window moves with the DTerm window and may extend past its bottom edge, the way the Tab-completion popup does.
3. **The panel must not activate the app**, because the DTerm window doesn't. So the panel is an `NSPanel` with `NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel`, subclassed so `canBecomeKeyWindow` returns `YES`.

### Trigger
- Add a menu item "Search History…" with shortcut ⌃R to the action menu in `TermWindow.xib`, next to "Pull Command from Results" (`:73`).
  - Its action is `showHistorySearch:` on File's Owner.
  - Its `enabled` binding is `commandFieldEditor.isFirstResponder`, like "Insert Selected Items".
  - This follows how the other shortcuts are set up, and it makes the shortcut visible in the menu.
- Ctrl-R has no default meaning in macOS text fields, so nothing clashes.
- Fallback if the popup button doesn't pick up the ⌃ shortcut: override `keyDown:` in `DTCommandFieldEditor` to catch ⌃R and call `[controller showHistorySearch:self]`.

### New class: `Term Window/DTHistorySearchController.h/.m`
The panel is built in code, with no new xib. It is an `NSObject` that acts as delegate and data source for its views.

**Views**
- `DTHistorySearchPanel`, a small `NSPanel` subclass in the same file (`canBecomeKeyWindow` returns `YES`).
- Dark appearance and an `NSVisualEffectView` background with the HUD material, to match the DTerm window.
- A plain `NSTextField` for the query at the top. Not `NSSearchField`, whose own Esc handling would clash with ours.
- An `NSScrollView` with a single-column `NSTableView` below it, using the font from `DTFontNameKey` / `DTFontSizeKey`.

**API**
```objc
- (void)showBelowScreenRect:(NSRect)anchor
               parentWindow:(NSWindow*)parent
                    history:(NSArray<NSString*>*)history      // oldest first
                 completion:(void (^)(NSString* chosenOrNil))completion;
- (void)close;                   // closes and calls completion(nil)
@property (readonly) BOOL isOpen;
```

**Behavior**
- The text field's delegate:
  - `controlTextDidChange:` re-runs the filter, reloads the table and selects row 0.
  - `control:textView:doCommandBySelector:` handles:
    - `moveUp:` / `moveDown:` (and so also Ctrl-P / Ctrl-N): move the table selection and scroll it into view;
    - `insertNewline:`: finish with the selected command;
    - `cancelOperation:` (Esc): finish with `nil`.
  - Each of these returns `YES`, so the key goes no further.
- Double-clicking a row also chooses it.
- Optional: pressing ⌃R again inside the panel moves down to the next older match, as in bash.
- Panel size: the width of the DTerm window. The height fits up to about 12 rows and is kept on-screen.

**Losing focus**
- In the panel's `windowDidResignKey:`, check the new key window on the next run-loop turn with `dispatch_async`.
- If focus left the app, close the panel with `nil`, then call `deactivate` on the term controller through the completion or a delegate callback.

**Fuzzy matching**
- A static function in the same file: a case-insensitive "letters appear in order" match, like fzf.
- Scoring:
  - bonus for matched letters that sit next to each other;
  - bonus for a match at the start of a word (after a space, `/`, `-`, `_` or `.`);
  - penalty for a match that starts late;
  - more recent commands win ties.
- Before matching, remove duplicate commands and keep the most recent copy.
- An empty query shows the whole history, newest first.
- Show at most about 200 rows.
- Optional polish: bold the matched letters in each row.

### Hooking it into `DTTermWindowController`
- `showHistorySearch:` (IBAction):
  - Create the controller on first use.
  - Work out the command field's position on screen.
  - Pass the panel `commandHistory` and a completion block. The block:
    - calls `replaceCommandFieldText:` if a command was chosen (it doesn't run it);
    - resets the history position;
    - makes the DTerm window key again and gives the command field focus.
- `windowDidResignKey:` (`:169`): return early if `historySearch.isOpen`, so DTerm doesn't hide while the panel has focus.
- `deactivate` (`:137`): close the search panel if it's open, e.g. when the global hotkey hides DTerm.
- **Order when finishing:** mark the panel closed first, then remove it from the parent window and hide it, then make the parent key again. Otherwise the parent's `windowDidResignKey:` guard can see a stale "open" state.

### Project file
Add `DTHistorySearchController.h/.m` to the DTerm target in `DTerm.xcodeproj/project.pbxproj`, either in Xcode or by adding the file references, build-file entries and group entries by hand.

---

## Edge cases
- **Empty history:** ↑ beeps (`NSBeep()`), and Ctrl-R opens with an empty list, where Enter does nothing (or closes the panel).
- **Editing a recalled command** and then pressing ↑ or ↓ throws the edit away, as bash does by default.
- **A command running in the background** may resize the DTerm window through `requestWindowHeightChange:`. The child panel moves with it. Its position isn't updated after a resize, which is acceptable for now.
- **Clicking another app** while the panel is open closes the panel and hides DTerm, the same as without the panel.

## Verification
- Build with `./build.sh` or in Xcode, then open DTerm with its hotkey.
- **↑ / ↓:**
  - Run `ls`, `pwd` and `echo hi`. ↑↑↑ should show `echo hi`, then `pwd`, then `ls`; ↓ steps forward again.
  - Type partial text, press ↑ then ↓: the partial text should come back.
  - Tab completion should still work.
- **Ctrl-R:**
  - The panel opens below the field, with focus in its search box.
  - Typing `eh` should match `echo hi`, and the list should update on every keystroke.
  - ↑ and ↓ move the selection.
  - Enter fills in the command field with the command, not run, and the cursor at the end.
  - Esc closes the panel and leaves the field unchanged.
  - DTerm must **not** hide while the panel is open. Clicking another app while the panel is open hides both.
- **Optional saving:** quit and relaunch, then check that ↑ and Ctrl-R still show earlier commands.
