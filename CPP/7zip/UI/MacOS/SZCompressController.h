// SZCompressController.h

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/*
  "Add to Archive" dialog. It's similar to CompressDialog in Windows version.
  The dialog creates command line for 7-Zip engine:
    "a" / "u" + switches + "--" + archive path + file paths
*/

@interface SZCompressRequest : NSObject
@property (copy) NSString *archivePath;
@property (copy) NSArray<NSString *> *args;   // full command line (without program name)
@property (copy) NSString *formatName;
@end

@interface SZCompressController : NSWindowController

+ (void)showForFiles:(NSArray<NSString *> *)files
         archivePath:(NSString *)archivePath
              parent:(nullable NSWindow *)parent
          completion:(void (^)(SZCompressRequest * _Nullable request))completion;

// default archive path for files ("folder/name.7z")
+ (NSString *)defaultArchivePathForFiles:(NSArray<NSString *> *)files extension:(NSString *)ext;

// command line for quick compression without dialog ("Compress to name.7z")
+ (NSArray<NSString *> *)quickArgsForFiles:(NSArray<NSString *> *)files archivePath:(NSString *)archivePath format:(NSString *)format;

@end

NS_ASSUME_NONNULL_END
