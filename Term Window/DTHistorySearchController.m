//  DTHistorySearchController.m
//  Fuzzy search through the command history (⌃R), shown in a borderless child panel below the command field

#import "DTHistorySearchController.h"

#import "DTAppController.h"

static const NSUInteger DTHistorySearchMaxResults = 200;
static const NSUInteger DTHistorySearchMaxVisibleRows = 12;
static const CGFloat DTHistorySearchPadding = 8.0;
static const CGFloat DTHistorySearchQueryHeight = 22.0;
static const CGFloat DTHistorySearchSpacing = 6.0;
static const CGFloat DTHistorySearchCornerRadius = 6.0;

#pragma mark Fuzzy matching

// Every matched character scores DTScoreMatch plus any bonuses.  Characters skipped between two matches
// cost DTPenaltyGap each, and characters before the first match cost DTPenaltyLeading each (capped).
static const NSInteger DTScoreMatch = 16;
static const NSInteger DTBonusWordStart = 10;
static const NSInteger DTBonusConsecutive = 8;
static const NSInteger DTPenaltyGap = 1;
static const NSInteger DTPenaltyLeading = 1;
static const NSInteger DTPenaltyLeadingMax = 15;

static BOOL DTIsWordSeparator(unichar c) {
	switch(c) {
		case ' ': case '\t': case '/': case '-': case '_': case '.':
		case '=': case ':': case ',': case ';': case '|': case '&':
		case '(': case '\'': case '"':
			return YES;
		default:
			return NO;
	}
}

// Case-insensitive fzf-style match: every character of `query` (already lowercased) must appear in
// `candidate` in the same order.  Of all the ways to line them up, the best-scoring one is used.
// Returns NO if there's no match; otherwise sets the score and the positions of the matched characters.
static BOOL DTFuzzyMatch(NSString* query, NSString* candidate, NSInteger* outScore, NSIndexSet** outMatched) {
	NSUInteger m = [query length], n = [candidate length];
	if(!m) {
		*outScore = 0;
		*outMatched = [NSIndexSet indexSet];
		return YES;
	}
	if(m > n)
		return NO;

	// Compare lowercased, unless lowercasing changes the length (and so the positions)
	NSString* folded = [candidate lowercaseString];
	if([folded length] != n)
		folded = candidate;

	NSMutableData* charData = [NSMutableData dataWithLength:(m + 2*n) * sizeof(unichar)];
	unichar* q = [charData mutableBytes];
	unichar* f = q + m;
	unichar* orig = f + n;
	[query getCharacters:q range:NSMakeRange(0, m)];
	[folded getCharacters:f range:NSMakeRange(0, n)];
	[candidate getCharacters:orig range:NSMakeRange(0, n)];

	// Cheap rejection before the real scoring
	NSUInteger qi = 0;
	for(NSUInteger j = 0; j < n && qi < m; j++) {
		if(f[j] == q[qi])
			qi++;
	}
	if(qi < m)
		return NO;

	// Dynamic programming over (query character i, candidate position j): the best score so far with q[i]
	// matched at f[j].  Only the previous row of scores is needed; `from` records where q[i-1] was matched
	// for each cell, so the matched positions can be traced back at the end.
	const NSInteger none = NSIntegerMin / 2;
	NSMutableData* scoreData = [NSMutableData dataWithLength:2 * n * sizeof(NSInteger)];
	NSInteger* prev = [scoreData mutableBytes];
	NSInteger* cur = prev + n;
	NSMutableData* fromData = [NSMutableData dataWithLength:m * n * sizeof(int32_t)];
	int32_t* from = [fromData mutableBytes];

	for(NSUInteger j = 0; j < n; j++) {
		if(f[j] == q[0]) {
			NSInteger bonus = (j == 0 || DTIsWordSeparator(orig[j-1])) ? DTBonusWordStart : 0;
			prev[j] = DTScoreMatch + bonus - MIN((NSInteger)j * DTPenaltyLeading, DTPenaltyLeadingMax);
		} else {
			prev[j] = none;
		}
	}

	for(NSUInteger i = 1; i < m; i++) {
		// Best of prev[k] - DTPenaltyGap * (j-1-k) over k <= j-2, i.e. coming from a match with a gap
		NSInteger gapBest = none;
		NSInteger gapFrom = -1;

		for(NSUInteger j = 0; j < n; j++) {
			if(j >= 2) {
				if(gapBest != none)
					gapBest -= DTPenaltyGap;
				if(prev[j-2] != none && prev[j-2] - DTPenaltyGap > gapBest) {
					gapBest = prev[j-2] - DTPenaltyGap;
					gapFrom = (NSInteger)j - 2;
				}
			}

			cur[j] = none;
			if(f[j] != q[i])
				continue;

			NSInteger best = none;
			NSInteger bestFrom = -1;
			if(j >= 1 && prev[j-1] != none) {
				best = prev[j-1] + DTBonusConsecutive;
				bestFrom = (NSInteger)j - 1;
			}
			if(gapBest > best) {
				best = gapBest;
				bestFrom = gapFrom;
			}
			if(best == none)
				continue;

			NSInteger bonus = DTIsWordSeparator(orig[j-1]) ? DTBonusWordStart : 0;
			cur[j] = best + DTScoreMatch + bonus;
			from[i*n + j] = (int32_t)bestFrom;
		}

		NSInteger* swap = prev;
		prev = cur;
		cur = swap;
	}

	NSInteger bestScore = none;
	NSUInteger end = 0;
	for(NSUInteger j = 0; j < n; j++) {
		if(prev[j] > bestScore) {
			bestScore = prev[j];
			end = j;
		}
	}
	if(bestScore == none)
		return NO;

	NSMutableIndexSet* matched = [NSMutableIndexSet indexSet];
	NSUInteger j = end;
	for(NSUInteger i = m; i-- > 0; ) {
		[matched addIndex:j];
		if(i > 0)
			j = (NSUInteger)from[i*n + j];
	}

	*outScore = bestScore;
	*outMatched = matched;
	return YES;
}

@interface DTHistoryMatch : NSObject
@property (nonatomic, copy) NSString* command;
@property (nonatomic) NSIndexSet* matchedIndexes;
@property (nonatomic) NSInteger score;
@property (nonatomic) NSUInteger age;	// position in the newest-first list
@end

@implementation DTHistoryMatch
@end

// `candidates` is newest first, with no duplicates.  Returns the best matches first; ties go to the
// more recent command, so an empty query lists the history newest first.
static NSArray<DTHistoryMatch*>* DTHistoryMatches(NSArray<NSString*>* candidates, NSString* query) {
	NSString* foldedQuery = [query lowercaseString];

	NSMutableArray<DTHistoryMatch*>* matches = [NSMutableArray array];
	[candidates enumerateObjectsUsingBlock:^(NSString* candidate, NSUInteger idx, BOOL* __unused stop) {
		NSInteger score = 0;
		NSIndexSet* matched = nil;
		if(DTFuzzyMatch(foldedQuery, candidate, &score, &matched)) {
			DTHistoryMatch* match = [[DTHistoryMatch alloc] init];
			match.command = candidate;
			match.matchedIndexes = matched;
			match.score = score;
			match.age = idx;
			[matches addObject:match];
		}
	}];

	[matches sortUsingComparator:^NSComparisonResult(DTHistoryMatch* a, DTHistoryMatch* b) {
		if(a.score != b.score)
			return (a.score > b.score) ? NSOrderedAscending : NSOrderedDescending;
		if(a.age != b.age)
			return (a.age < b.age) ? NSOrderedAscending : NSOrderedDescending;
		return NSOrderedSame;
	}];

	if([matches count] > DTHistorySearchMaxResults)
		[matches removeObjectsInRange:NSMakeRange(DTHistorySearchMaxResults, [matches count] - DTHistorySearchMaxResults)];

	return matches;
}

#pragma mark Views

static NSImage* DTRoundedMaskImage(CGFloat radius) {
	CGFloat edge = 2.0 * radius + 1.0;
	NSImage* mask = [NSImage imageWithSize:NSMakeSize(edge, edge)
								   flipped:NO
							drawingHandler:^BOOL(NSRect rect) {
		[[NSColor blackColor] setFill];
		[[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
		return YES;
	}];
	[mask setCapInsets:NSEdgeInsetsMake(radius, radius, radius, radius)];
	[mask setResizingMode:NSImageResizingModeStretch];
	return mask;
}

@interface DTHistorySearchController () <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (readwrite) BOOL isOpen;
- (void)selectRowOffsetBy:(NSInteger)delta;
@end

@interface DTHistorySearchPanel : NSPanel
@property (nonatomic, weak) DTHistorySearchController* searchController;
@end

@implementation DTHistorySearchPanel

// Borderless windows can't become key by default
- (BOOL)canBecomeKeyWindow {
	return YES;
}

// ⌃R again moves on to the next match, as in bash
- (BOOL)performKeyEquivalent:(NSEvent*)event {
	NSEventModifierFlags modifiers = [event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
															   NSEventModifierFlagControl | NSEventModifierFlagShift);
	if(modifiers == NSEventModifierFlagControl && [[event charactersIgnoringModifiers] isEqualToString:@"r"]) {
		[self.searchController selectRowOffsetBy:1];
		return YES;
	}

	return [super performKeyEquivalent:event];
}

@end

@interface DTHistorySearchTableView : NSTableView
@end

@implementation DTHistorySearchTableView

// The table never becomes first responder (typing stays in the query field), so AppKit would draw
// the selection in the inactive grey.  Draw it in the accent colour instead.
- (void)highlightSelectionInClipRect:(NSRect) __unused clipRect {
	[[NSColor selectedContentBackgroundColor] setFill];
	[[self selectedRowIndexes] enumerateIndexesUsingBlock:^(NSUInteger row, BOOL* __unused stop) {
		[[NSBezierPath bezierPathWithRoundedRect:[self rectOfRow:(NSInteger)row] xRadius:4.0 yRadius:4.0] fill];
	}];
}

@end

@interface DTHistorySearchCell : NSTextFieldCell
@end

@implementation DTHistorySearchCell

// Otherwise the cell paints its own grey highlight over the table's
- (NSColor*)highlightColorWithFrame:(NSRect) __unused cellFrame inView:(NSView*) __unused controlView {
	return nil;
}

@end

#pragma mark -

@implementation DTHistorySearchController {
	DTHistorySearchPanel* panel;
	NSTextField* queryField;
	DTHistorySearchTableView* tableView;

	NSWindow* __weak parentWindow;
	void (^completionBlock)(NSString*, BOOL);

	NSArray<NSString*>* candidates;		// unique commands, newest first
	NSArray<DTHistoryMatch*>* matches;

	NSFont* font;
	NSFont* matchFont;
	NSParagraphStyle* paragraphStyle;
}

- (void)createPanel {
	NSRect contentRect = NSMakeRect(0.0, 0.0, 480.0, 300.0);
	CGFloat width = NSWidth(contentRect);
	CGFloat height = NSHeight(contentRect);

	panel = [[DTHistorySearchPanel alloc] initWithContentRect:contentRect
													styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
													  backing:NSBackingStoreBuffered
														defer:YES];
	panel.searchController = self;
	panel.delegate = self;
	panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
	panel.opaque = NO;
	panel.backgroundColor = [NSColor clearColor];
	panel.hasShadow = YES;
	panel.hidesOnDeactivate = NO;
	panel.releasedWhenClosed = NO;

	NSVisualEffectView* background = [[NSVisualEffectView alloc] initWithFrame:contentRect];
	background.material = NSVisualEffectMaterialHUDWindow;
	background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
	background.state = NSVisualEffectStateActive;
	background.maskImage = DTRoundedMaskImage(DTHistorySearchCornerRadius);
	panel.contentView = background;

	// A plain text field, not an NSSearchField, whose own Esc handling would get in the way
	queryField = [[NSTextField alloc] initWithFrame:NSMakeRect(DTHistorySearchPadding,
															   height - DTHistorySearchPadding - DTHistorySearchQueryHeight,
															   width - 2.0*DTHistorySearchPadding,
															   DTHistorySearchQueryHeight)];
	queryField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	queryField.bezeled = YES;
	queryField.bezelStyle = NSTextFieldRoundedBezel;
	queryField.focusRingType = NSFocusRingTypeNone;
	queryField.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
	queryField.usesSingleLineMode = YES;
	queryField.cell.scrollable = YES;
	queryField.delegate = self;
	[background addSubview:queryField];

	DTHistorySearchCell* cell = [[DTHistorySearchCell alloc] initTextCell:@""];
	cell.editable = NO;
	cell.lineBreakMode = NSLineBreakByTruncatingTail;

	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"command"];
	column.editable = NO;
	column.resizingMask = NSTableColumnAutoresizingMask;
	column.dataCell = cell;

	tableView = [[DTHistorySearchTableView alloc] initWithFrame:NSZeroRect];
	[tableView addTableColumn:column];
	tableView.headerView = nil;
	tableView.style = NSTableViewStylePlain;
	tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	tableView.intercellSpacing = NSMakeSize(6.0, 4.0);	// half of it ends up on each side of the text
	tableView.backgroundColor = [NSColor clearColor];
	tableView.focusRingType = NSFocusRingTypeNone;
	tableView.refusesFirstResponder = YES;
	tableView.allowsEmptySelection = YES;
	tableView.allowsMultipleSelection = NO;
	tableView.dataSource = self;
	tableView.delegate = self;
	tableView.target = self;
	tableView.doubleAction = @selector(chooseClickedRow:);
	[tableView setAccessibilityLabel:NSLocalizedString(@"Command history", @"history search list accessibility label")];

	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(DTHistorySearchPadding,
																			  DTHistorySearchPadding,
																			  width - 2.0*DTHistorySearchPadding,
																			  height - 2.0*DTHistorySearchPadding - DTHistorySearchQueryHeight - DTHistorySearchSpacing)];
	scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scrollView.borderType = NSNoBorder;
	scrollView.drawsBackground = NO;
	scrollView.hasVerticalScroller = YES;
	scrollView.autohidesScrollers = YES;
	scrollView.documentView = tableView;
	[background addSubview:scrollView];
	[tableView sizeLastColumnToFit];

	NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
	style.lineBreakMode = NSLineBreakByTruncatingTail;
	paragraphStyle = style;
}

// The list uses the terminal font from the preferences, which may have changed since last time
- (void)updateFont {
	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
	NSString* fontName = [defaults stringForKey:DTFontNameKey];
	CGFloat fontSize = (CGFloat)[defaults doubleForKey:DTFontSizeKey];

	font = fontName ? [NSFont fontWithName:fontName size:fontSize] : nil;
	if(!font)
		font = [NSFont userFixedPitchFontOfSize:fontSize];
	// Stays the same font if it has no bold face; the colour still marks the matches
	matchFont = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSBoldFontMask];

	tableView.rowHeight = ceil([[[NSLayoutManager alloc] init] defaultLineHeightForFont:font]);
}

- (void)showBelowScreenRect:(NSRect)anchor
			   parentWindow:(NSWindow*)parent
					history:(NSArray<NSString*>*)history
				 completion:(void (^)(NSString* chosenOrNil, BOOL lostFocus))completion {
	[self close];
	if(!panel)
		[self createPanel];

	// Drop duplicates, keeping the most recent copy
	NSMutableArray<NSString*>* uniqueCommands = [NSMutableArray arrayWithCapacity:[history count]];
	NSMutableSet<NSString*>* seen = [NSMutableSet setWithCapacity:[history count]];
	for(NSString* historyCommand in [history reverseObjectEnumerator]) {
		if(![seen containsObject:historyCommand]) {
			[seen addObject:historyCommand];
			[uniqueCommands addObject:historyCommand];
		}
	}
	candidates = uniqueCommands;

	[self updateFont];
	[queryField setStringValue:@""];
	[queryField setPlaceholderString:([candidates count] ?
									  NSLocalizedString(@"Search command history", @"history search placeholder") :
									  NSLocalizedString(@"No command history yet", @"history search placeholder when the history is empty"))];
	[self updateMatches];

	// Just below the anchor, tall enough for up to DTHistorySearchMaxVisibleRows rows, and on-screen
	NSScreen* screen = [parent screen] ? [parent screen] : [NSScreen mainScreen];
	NSRect visibleFrame = [screen visibleFrame];
	CGFloat rowPitch = [tableView rowHeight] + [tableView intercellSpacing].height;
	CGFloat chromeHeight = 2.0*DTHistorySearchPadding + DTHistorySearchQueryHeight + DTHistorySearchSpacing;
	CGFloat top = NSMinY(anchor) - 2.0;
	NSUInteger rows = MAX((NSUInteger)1, MIN([candidates count], DTHistorySearchMaxVisibleRows));
	while(rows > 1 && top - (chromeHeight + rows*rowPitch) < NSMinY(visibleFrame))
		rows--;
	CGFloat height = chromeHeight + rows*rowPitch;

	NSRect frame = NSMakeRect(NSMinX(anchor), top - height, NSWidth(anchor), height);
	frame.origin.x = MAX(NSMinX(visibleFrame), MIN(NSMinX(frame), NSMaxX(visibleFrame) - NSWidth(frame)));
	frame.origin.y = MAX(NSMinY(visibleFrame), NSMinY(frame));
	[panel setFrame:frame display:NO];
	[tableView sizeLastColumnToFit];

	parentWindow = parent;
	completionBlock = [completion copy];

	// Open before taking key status: the parent's resign-key handling checks isOpen
	self.isOpen = YES;
	[panel setLevel:[parent level]];
	[parent addChildWindow:panel ordered:NSWindowAbove];
	[panel makeKeyAndOrderFront:self];
	[panel makeFirstResponder:queryField];
	[panel invalidateShadow];
}

- (void)moveBelowScreenRect:(NSRect)anchor {
	if(!self.isOpen)
		return;

	NSRect frame = [panel frame];
	frame.origin.x = NSMinX(anchor);
	frame.origin.y = NSMinY(anchor) - 2.0 - NSHeight(frame);
	frame.size.width = NSWidth(anchor);

	NSScreen* screen = [parentWindow screen] ? [parentWindow screen] : [NSScreen mainScreen];
	frame.origin.y = MAX(NSMinY([screen visibleFrame]), NSMinY(frame));
	[panel setFrame:frame display:YES];
}

- (void)close {
	if(!self.isOpen)
		return;

	self.isOpen = NO;
	[self hidePanel];
}

- (void)hidePanel {
	completionBlock = nil;
	[parentWindow removeChildWindow:panel];
	parentWindow = nil;
	[panel orderOut:self];
}

- (void)finishWithCommand:(NSString*)chosen lostFocus:(BOOL)lostFocus {
	if(!self.isOpen)
		return;

	void (^completion)(NSString*, BOOL) = completionBlock;
	NSWindow* parent = parentWindow;

	// Mark closed before anything changes key status, since the parent's resign-key handling checks isOpen.
	// Give the parent key status back before hiding the panel, so focus doesn't bounce to another app.
	self.isOpen = NO;
	if(!lostFocus)
		[parent makeKeyWindow];
	[self hidePanel];

	if(completion)
		completion(chosen, lostFocus);
}

- (void)updateMatches {
	matches = DTHistoryMatches(candidates, [queryField stringValue]);
	[tableView reloadData];
	if([matches count]) {
		[tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		[tableView scrollRowToVisible:0];
	}
}

- (void)selectRowOffsetBy:(NSInteger)delta {
	NSInteger count = (NSInteger)[matches count];
	if(!count)
		return;

	NSInteger row = [tableView selectedRow];
	NSInteger newRow = (row < 0) ? 0 : MAX(0, MIN(count - 1, row + delta));
	[tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)newRow] byExtendingSelection:NO];
	[tableView scrollRowToVisible:newRow];
}

- (NSInteger)visibleRowCount {
	CGFloat rowPitch = [tableView rowHeight] + [tableView intercellSpacing].height;
	return MAX(1, (NSInteger)floor(NSHeight([tableView visibleRect]) / rowPitch));
}

- (void)chooseRow:(NSInteger)row {
	NSString* chosen = (row >= 0 && row < (NSInteger)[matches count]) ? matches[(NSUInteger)row].command : nil;
	[self finishWithCommand:chosen lostFocus:NO];
}

- (void)chooseClickedRow:(id) __unused sender {
	NSInteger row = [tableView clickedRow];
	if(row >= 0)
		[self chooseRow:row];
}

#pragma mark query field delegate

- (void)controlTextDidChange:(NSNotification*) __unused notification {
	[self updateMatches];
}

- (BOOL)control:(NSControl*) __unused control textView:(NSTextView*) __unused textView doCommandBySelector:(SEL)selector {
	// ↑ / ↓ include ⌃P / ⌃N, which the text system maps to the same selectors
	if(selector == @selector(moveUp:))
		[self selectRowOffsetBy:-1];
	else if(selector == @selector(moveDown:))
		[self selectRowOffsetBy:1];
	else if(selector == @selector(scrollPageUp:))
		[self selectRowOffsetBy:-[self visibleRowCount]];
	else if(selector == @selector(scrollPageDown:))
		[self selectRowOffsetBy:[self visibleRowCount]];
	else if(selector == @selector(insertNewline:))
		[self chooseRow:[tableView selectedRow]];
	else if(selector == @selector(cancelOperation:))
		[self finishWithCommand:nil lostFocus:NO];
	else if(selector == @selector(insertTab:) || selector == @selector(insertBacktab:))
		;	// keep the focus in the query field
	else
		return NO;

	return YES;
}

#pragma mark table data source/delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView*) __unused aTableView {
	return (NSInteger)[matches count];
}

- (id)tableView:(NSTableView*)aTableView objectValueForTableColumn:(NSTableColumn*) __unused column row:(NSInteger)row {
	if(row < 0 || row >= (NSInteger)[matches count])
		return nil;

	DTHistoryMatch* match = matches[(NSUInteger)row];
	BOOL selected = [aTableView isRowSelected:row];

	// Keep each command on one line.  Every tab or line break becomes one space, so the match positions still line up.
	NSCharacterSet* lineBreaks = [NSCharacterSet characterSetWithCharactersInString:@"\t\n\r"];
	NSString* displayCommand = [[match.command componentsSeparatedByCharactersInSet:lineBreaks] componentsJoinedByString:@" "];

	NSColor* textColor = selected ? [NSColor alternateSelectedControlTextColor] : [NSColor labelColor];
	NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:displayCommand
																			  attributes:@{NSFontAttributeName: font,
																						   NSForegroundColorAttributeName: textColor,
																						   NSParagraphStyleAttributeName: paragraphStyle}];

	NSDictionary* matchAttributes = selected ?
		@{NSFontAttributeName: matchFont, NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)} :
		@{NSFontAttributeName: matchFont, NSForegroundColorAttributeName: [NSColor systemYellowColor]};
	[match.matchedIndexes enumerateRangesUsingBlock:^(NSRange range, BOOL* __unused stop) {
		[title addAttributes:matchAttributes range:range];
	}];

	return title;
}

- (BOOL)tableView:(NSTableView*) __unused aTableView shouldEditTableColumn:(NSTableColumn*) __unused column row:(NSInteger) __unused row {
	return NO;
}

#pragma mark window delegate

- (void)windowDidResignKey:(NSNotification*) __unused notification {
	// Look at where the focus went once the key window change has settled
	dispatch_async(dispatch_get_main_queue(), ^{
		if(!self.isOpen || [self->panel isKeyWindow])
			return;

		// A click back in the DTerm window just ends the search.  Focus going anywhere else hides DTerm too.
		NSWindow* parent = self->parentWindow;
		[self finishWithCommand:nil lostFocus:![parent isKeyWindow]];
	});
}

@end
