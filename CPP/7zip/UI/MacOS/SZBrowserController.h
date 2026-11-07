// SZBrowserController.h

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/*
  Main window of 7-Zip: file manager that shows folders and archives.
  It's similar to 7-Zip File Manager (7zFM.exe) in Windows.
*/

@interface SZBrowserController : NSWindowController

// opens new window for folder or archive
+ (SZBrowserController *)openWindowWithPath:(NSString *)path;

+ (NSArray<SZBrowserController *> *)allBrowsers;

- (void)navigateToPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
