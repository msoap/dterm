//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

@class DTCommandFieldEditor;
@class DTHistorySearchController;
@class DTResultsView;
@class DTResultsTextView;

@interface DTTermWindowController : NSWindowController {
	NSString* workingDirectory;
	NSArray* selectedURLs;
	
	NSString* command;
	IBOutlet NSPopUpButton* actionButton;
	IBOutlet NSMenu* actionMenu;
	
	NSMutableArray* runs;
	IBOutlet NSArrayController* runsController;
	IBOutlet NSView* placeholderForResultsView;
	IBOutlet DTResultsView* resultsView;
	IBOutlet DTResultsTextView* resultsTextView;
	
	IBOutlet NSTextField* commandField;
	DTCommandFieldEditor* commandFieldEditor;

	NSMutableArray<NSString*>* commandHistory;	// oldest first
	NSUInteger historyIndex;					// position while stepping with ↑/↓, NSNotFound otherwise
	NSString* historyDraft;						// what was typed before the first ↑
	DTHistorySearchController* historySearch;
}

@property NSString* workingDirectory;
@property NSArray* selectedURLs;
@property (nonatomic) NSString* command;
@property NSMutableArray* runs;
@property NSArrayController* runsController;

- (void)activateWithWorkingDirectory:(NSString*)wdPath
						   selection:(NSArray*)selection
						 windowFrame:(NSRect)frame;
- (void)deactivate;

- (void)requestWindowHeightChange:(CGFloat)dHeight;

- (IBAction)insertSelection:(id)sender;
- (IBAction)insertSelectionFullPaths:(id)sender;
- (IBAction)pullCommandFromResults:(id)sender;
- (IBAction)showHistorySearch:(id)sender;
- (IBAction)executeCommand:(id)sender;
- (IBAction)executeCommandInTerminal:(id)sender;
- (IBAction)copyResultsToClipboard:(id)sender;
- (IBAction)cancelCurrentCommand:(id)sender;

- (void)historyPrevious;
- (void)historyNext;

- (NSArray*)completionsForPartialWord:(NSString*)partialWord
							isCommand:(BOOL)isCommand
				  indexOfSelectedItem:(NSInteger*)index;

@end
