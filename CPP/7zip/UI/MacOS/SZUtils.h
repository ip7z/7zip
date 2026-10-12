// SZUtils.h

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

NSString *SZString(const char * _Nullable utf8);

NSString *SZFormatSize(uint64_t size);       // "12.3 MB"
NSString *SZFormatSizeExact(uint64_t size);  // "12 345 678"
NSString *SZFormatDate(NSDate *date);
NSString *SZFormatDuration(double seconds);  // "00:01:23"
NSString *SZFormatAttrib(uint32_t attrib);

// SF Symbol image
NSImage * _Nullable SZSymbol(NSString *name, CGFloat pointSize);

// returns YES, if the file can be opened as archive (by extension)
BOOL SZIsArchivePath(NSString *path);

// controls
NSTextField *SZLabel(NSString *text);
NSTextField *SZSecondaryLabel(NSString *text);
NSTextField *SZBoldLabel(NSString *text);
NSButton *SZCheckbox(NSString *title, BOOL on);
NSPopUpButton *SZPopUp(NSArray<NSString *> *items);
NSButton *SZPushButton(NSString *title, id _Nullable target, SEL _Nullable action);
NSBox *SZSeparator(void);
NSGridView *SZFormGrid(NSArray<NSArray<NSView *> *> *rows);

// NSGridView and NSStackView have no intrinsic size, so they can be stretched by layout.
// SZHug() adds low priority constraints that keep the view at its minimal size.
void SZHug(NSView *view);

// sets window content size to minimal size of the view (with autolayout)
void SZFitWindow(NSWindow *window, NSView *mainView);

// strips "&" from Windows menu strings ("&File" -> "File")
NSString *SZStripAmp(NSString *s);

void SZShowAlert(NSWindow * _Nullable window, NSString *message, NSString * _Nullable info, NSAlertStyle style);

// unique temporary folder for this process
NSString *SZTempFolder(void);
NSString *SZCreateTempSubfolder(void);

NS_ASSUME_NONNULL_END
