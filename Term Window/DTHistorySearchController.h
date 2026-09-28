//  DTHistorySearchController.h
//  Fuzzy search through the command history (⌃R), shown in a borderless child panel below the command field

@interface DTHistorySearchController : NSObject

@property (readonly) BOOL isOpen;

// Shows the panel as a child of `parent`, with its top edge just below `anchor` and the same x and width.
// `history` is oldest first.  `completion` is called once when the search ends: with the chosen command
// (Enter or double-click, not run), with nil (Esc, or a click back in `parent`), or with nil and
// lostFocus = YES when keyboard focus left the panel for anything but `parent`.
- (void)showBelowScreenRect:(NSRect)anchor
			   parentWindow:(NSWindow*)parent
					history:(NSArray<NSString*>*)history
				 completion:(void (^)(NSString* chosenOrNil, BOOL lostFocus))completion;

// Re-positions the open panel after the parent window has changed size
- (void)moveBelowScreenRect:(NSRect)anchor;

// Closes the panel without calling the completion block
- (void)close;

@end
