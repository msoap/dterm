//  DTAppController.h
//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

#import "SRCommon.h"

@class DTPrefsWindowController;
@class DTTermWindowController;
@class RTFWindowController;

@class SUUpdater;

extern NSString* const DTResultsToKeepKey;
extern NSString* const DTTextColorKey;
extern NSString* const DTFontNameKey;
extern NSString* const DTFontSizeKey;
extern NSString* const DTCommandHistoryKey;

@interface DTAppController : NSObject {
	IBOutlet SUUpdater* __unsafe_unretained sparkleUpdater;
	DTTermWindowController* termWindowController;
	
	RTFWindowController* acknowledgmentsWindowController;
	RTFWindowController* licenseWindowController;
	
	EventHotKeyRef hotKeyRef;
	KeyCombo hotKey;
}

@property (unsafe_unretained) SUUpdater* sparkleUpdater;
@property (readonly, nonatomic) DTPrefsWindowController* prefsWindowController;
@property (readonly) DTTermWindowController* termWindowController;

- (BOOL) isAXTrustedPromptIfNot:(BOOL)shouldPrompt;

- (IBAction)showPrefs:(id)sender;
- (IBAction)showAcknowledgments:(id)sender;
- (IBAction)showLicense:(id)sender;

- (KeyCombo)hotKey;
- (void)setHotKey:(KeyCombo)newHotKey;
- (void)hotkeyPressed;

- (void)saveHotKeyToUserDefaults;
- (void)loadHotKeyFromUserDefaults;

@end
