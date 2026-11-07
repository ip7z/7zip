// SZExtractController.h

#import <Cocoa/Cocoa.h>

#include "MacEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZExtractOptions : NSObject
@property (copy) NSString *outputDir;           // final output folder (with subfolder)
@property (copy) NSString *baseDir;             // folder that was selected by user
@property (nullable, copy) NSString *subfolder; // subfolder name or nil
@property NMacEngine::EPathMode pathMode;
@property NMacEngine::EOverwriteMode overwriteMode;
@property BOOL elimDup;
@property (nullable, copy) NSString *password;
@end

// Extract dialog. It's similar to ExtractDialog in Windows version.
@interface SZExtractController : NSWindowController

// subfolder: default name of subfolder ("archive" for "archive.7z"),
//   if it's nil, there is no subfolder option.
// showElimDup: show "Eliminate duplication of root folder" option.
+ (void)showWithDirectory:(NSString *)dir
                subfolder:(nullable NSString *)subfolder
              showElimDup:(BOOL)showElimDup
                   parent:(nullable NSWindow *)parent
               completion:(void (^)(SZExtractOptions * _Nullable options))completion;

@end

NS_ASSUME_NONNULL_END
