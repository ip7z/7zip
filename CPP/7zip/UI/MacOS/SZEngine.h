// SZEngine.h

#import <Cocoa/Cocoa.h>

#include "MacEngine.h"

NS_ASSUME_NONNULL_BEGIN

@class SZOperation;

// description of file for overwrite dialog
@interface SZFileDesc : NSObject
@property (copy) NSString *path;
@property (nullable, strong) NSNumber *size;
@property (nullable, strong) NSDate *date;
@end


// the object that shows questions to user (password, overwrite).
// The methods are called in main thread.
@protocol SZOperationPrompts <NSObject>
- (void)operation:(SZOperation *)op askPasswordWithCompletion:(void (^)(NSString * _Nullable password))completion;
- (void)operation:(SZOperation *)op askOverwriteExisting:(SZFileDesc *)existing
    withNew:(SZFileDesc *)newFile completion:(void (^)(NMacEngine::EOverwriteAnswer answer))completion;
@end


struct SZProgressSnapshot
{
  uint64_t Total;
  uint64_t Completed;
  uint64_t InSize;
  uint64_t OutSize;
  uint64_t NumFiles;
  uint64_t NumFilesTotal;
  uint64_t NumErrors;
  NMacEngine::EOperation Op;
  bool RatioDefined;
};


/*
  SZOperation : one operation (compressing, extracting, testing ...)
  The engine updates the state from worker thread,
  and the progress window reads the state with timer.
*/

@interface SZOperation : NSObject

- (instancetype)initWithTitle:(NSString *)title;

@property (copy) NSString *title;       // "Compressing"
@property (copy) NSString *subtitle;    // archive name
@property (atomic) BOOL cancelled;
@property (nonatomic) BOOL paused;
@property (weak, nullable) id<SZOperationPrompts> prompts;
// if (quiet), the progress window doesn't show the list of messages at the end
@property BOOL quiet;

@property (readonly) NMacEngine::IUserCallback *callback;
@property (assign) NMacEngine::CResult result;

// password that was entered by user in this operation
@property (nullable, copy) NSString *enteredPassword;

- (SZProgressSnapshot)snapshot;
- (NSString *)currentFileName;
- (NSArray<NSString *> *)messages;
- (BOOL)hasErrors;
- (void)addMessage:(NSString *)message isError:(BOOL)isError;

// elapsed time without pauses
- (double)elapsedTime;

// the time when the operation waits for user answer is not counted in elapsed time
- (void)beginUserWait;
- (void)endUserWait;

@end


/*
  SZArchiveNode : file or folder in archive.
  Folders that have no item in archive have (itemIndex == -1).
*/

@interface SZArchiveNode : NSObject
@property (copy) NSString *name;
@property (weak, nullable) SZArchiveNode *parent;
@property (strong) NSMutableArray<SZArchiveNode *> *children;
@property NSInteger itemIndex;
@property BOOL isDir;
@property BOOL sizeDefined;
@property BOOL packSizeDefined;
@property BOOL crcDefined;
@property BOOL encrypted;
@property uint64_t size;
@property uint64_t packSize;
@property uint32_t crc;
@property uint32_t attrib;
@property BOOL attribDefined;
@property (nullable, strong) NSDate *mtime;
@property (copy) NSString *method;
@property uint64_t numFiles;    // for folders: number of files in all subfolders
@property uint64_t numFolders;

- (NSString *)pathInArchive;          // "dir/file.txt"
- (NSString *)folderPrefix;           // "dir/" for (dir) node, "" for root
- (void)collectItemIndices:(NSMutableIndexSet *)indices;
- (nullable SZArchiveNode *)childWithName:(NSString *)name;
- (nullable SZArchiveNode *)nodeAtPath:(NSString *)path;
@end


@interface SZArchive : NSObject
@property (readonly, copy) NSString *path;        // path of archive file
@property (copy) NSString *displayName;           // name for window title / address
@property (readonly, strong) SZArchiveNode *root;
@property (readonly) NMacEngine::IArchive *engineArchive;
@property (readonly) BOOL canUpdate;
@property (readonly, copy) NSString *formatName;

// parent archive for nested archives (archive inside archive)
@property (nullable, strong) SZArchive *parentArchive;
@property (nullable, copy) NSString *pathInParent;

- (instancetype)initWithEngineArchive:(NMacEngine::IArchive *)arc path:(NSString *)path;
@end


// path of 7-Zip engine arguments helpers
NSString *SZResultMessage(const NMacEngine::CResult &r);

NS_ASSUME_NONNULL_END
