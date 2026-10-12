// SZCommands.h

#import <Cocoa/Cocoa.h>

#import "SZEngine.h"
#import "SZExtractController.h"

NS_ASSUME_NONNULL_BEGIN

/*
  High level commands that are used by browser window and by Finder services.
  All commands show progress window. (parent) can be nil.
  completion is called in main thread. (ok) is YES, if operation was finished without errors.
*/

typedef void (^SZCommandCompletion)(BOOL ok);

typedef NS_ENUM(NSInteger, SZExtractMode)
{
  SZExtractModeDialog,     // show Extract dialog
  SZExtractModeHere,       // extract to folder of archive
  SZExtractModeToFolder    // extract to "folder of archive/archive name/"
};

// runs 7-Zip command line (args) in worker thread with progress window
void SZRunCommand(NSArray<NSString *> *args, NSString *title, NSString *subtitle,
    NSWindow * _Nullable parent, SZCommandCompletion _Nullable completion);

void SZCompressFiles(NSArray<NSString *> *files, NSWindow * _Nullable parent, SZCommandCompletion _Nullable completion);
void SZCompressFilesQuick(NSArray<NSString *> *files, NSString *format, NSWindow * _Nullable parent, SZCommandCompletion _Nullable completion);

void SZExtractArchives(NSArray<NSString *> *archives, SZExtractMode mode, NSWindow * _Nullable parent, SZCommandCompletion _Nullable completion);
void SZTestArchives(NSArray<NSString *> *archives, NSWindow * _Nullable parent, SZCommandCompletion _Nullable completion);

// shows message "There are no errors" after test
void SZShowTestResult(SZOperation *op, NSWindow * _Nullable parent);

// arguments for extraction options
NSArray<NSString *> *SZExtractSwitches(SZExtractOptions *o);

NS_ASSUME_NONNULL_END
