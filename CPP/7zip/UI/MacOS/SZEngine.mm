// SZEngine.mm

#import "SZEngine.h"
#import "SZPrompts.h"
#import "SZUtils.h"

#include <os/lock.h>
#include <string.h>

using namespace NMacEngine;

@implementation SZFileDesc
@end


class CUserCallbackImp;

@interface SZOperation ()
{
@public
  os_unfair_lock _lock;
  SZProgressSnapshot _state;
  NSString *_currentName;
  NSMutableArray<NSString *> *_messages;
  CUserCallbackImp *_callback;
  CResult _result;
  CFAbsoluteTime _startTime;
  CFAbsoluteTime _pauseStart;
  CFAbsoluteTime _waitStart;
  double _pausedTime;
}
@end


// C++ object that is called by the engine in worker thread

class CUserCallbackImp final: public IUserCallback
{
public:
  __weak SZOperation *Op;

  void SetTotal(uint64_t total) override
  {
    SZOperation *op = Op;
    os_unfair_lock_lock(&op->_lock);
    op->_state.Total = total;
    os_unfair_lock_unlock(&op->_lock);
  }

  void SetCompleted(uint64_t completed) override
  {
    SZOperation *op = Op;
    os_unfair_lock_lock(&op->_lock);
    op->_state.Completed = completed;
    os_unfair_lock_unlock(&op->_lock);
  }

  void SetRatioInfo(uint64_t inSize, uint64_t outSize) override
  {
    SZOperation *op = Op;
    os_unfair_lock_lock(&op->_lock);
    op->_state.InSize = inSize;
    op->_state.OutSize = outSize;
    op->_state.RatioDefined = true;
    os_unfair_lock_unlock(&op->_lock);
  }

  void SetNumFiles(uint64_t numFilesTotal) override
  {
    SZOperation *op = Op;
    os_unfair_lock_lock(&op->_lock);
    op->_state.NumFilesTotal = numFilesTotal;
    os_unfair_lock_unlock(&op->_lock);
  }

  void SetNumFilesCompleted(uint64_t numFiles) override
  {
    SZOperation *op = Op;
    os_unfair_lock_lock(&op->_lock);
    op->_state.NumFiles = numFiles;
    os_unfair_lock_unlock(&op->_lock);
  }

  void SetCurrent(EOperation opType, const char *name) override
  {
    SZOperation *op = Op;
    NSString *s = SZString(name);
    os_unfair_lock_lock(&op->_lock);
    op->_state.Op = opType;
    op->_currentName = s;
    os_unfair_lock_unlock(&op->_lock);
  }

  bool CheckBreak() override
  {
    SZOperation *op = Op;
    while (op.paused && !op.cancelled)
      [NSThread sleepForTimeInterval:0.1];
    return op.cancelled;
  }

  bool AskPassword(char *buf, size_t bufSize) override
  {
    SZOperation *op = Op;
    __block NSString *password = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      void (^done)(NSString *) = ^(NSString *p) {
        password = p;
        dispatch_semaphore_signal(sem);
      };
      if (op.prompts)
        [op.prompts operation:op askPasswordWithCompletion:done];
      else
        SZAskPassword(nil, op.subtitle, done);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (!password)
    {
      op.cancelled = YES;
      return false;
    }
    op.enteredPassword = password;
    const char *s = password.UTF8String;
    const size_t len = strlen(s);
    if (len >= bufSize)
      return false;
    memcpy(buf, s, len + 1);
    return true;
  }

  EOverwriteAnswer AskOverwrite(
      const char *existPath, const CFileInfo &existInfo,
      const char *newPath, const CFileInfo &newInfo) override
  {
    SZOperation *op = Op;
    SZFileDesc *e = Desc(existPath, existInfo);
    SZFileDesc *n = Desc(newPath, newInfo);
    __block EOverwriteAnswer answer = kOverwrite_Cancel;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      void (^done)(EOverwriteAnswer) = ^(EOverwriteAnswer a) {
        answer = a;
        dispatch_semaphore_signal(sem);
      };
      if (op.prompts)
        [op.prompts operation:op askOverwriteExisting:e withNew:n completion:done];
      else
        SZAskOverwrite(nil, e, n, done);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (answer == kOverwrite_Cancel)
      op.cancelled = YES;
    return answer;
  }

  void AddMessage(const char *message, bool isError) override
  {
    [Op addMessage:SZString(message) isError:isError];
  }

private:
  static SZFileDesc *Desc(const char *path, const CFileInfo &fi)
  {
    SZFileDesc *d = [[SZFileDesc alloc] init];
    d.path = SZString(path);
    if (fi.SizeDefined)
      d.size = @(fi.Size);
    if (fi.TimeDefined)
      d.date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)fi.UnixTime];
    return d;
  }
};


@implementation SZOperation

- (instancetype)initWithTitle:(NSString *)title
{
  self = [super init];
  if (self)
  {
    _title = [title copy];
    _subtitle = @"";
    _lock = OS_UNFAIR_LOCK_INIT;
    memset(&_state, 0, sizeof(_state));
    _currentName = @"";
    _messages = [NSMutableArray array];
    _callback = new CUserCallbackImp;
    _callback->Op = self;
    _result.Clear();
    _startTime = CFAbsoluteTimeGetCurrent();
  }
  return self;
}

- (void)dealloc
{
  delete _callback;
}

- (IUserCallback *)callback
{
  return _callback;
}

- (CResult)result
{
  return _result;
}

- (void)setResult:(CResult)result
{
  _result = result;
}

- (void)setPaused:(BOOL)paused
{
  @synchronized (self)
  {
    if (paused == _paused)
      return;
    _paused = paused;
    if (paused)
      _pauseStart = CFAbsoluteTimeGetCurrent();
    else
      _pausedTime += CFAbsoluteTimeGetCurrent() - _pauseStart;
  }
}

- (void)beginUserWait
{
  @synchronized (self)
  {
    _waitStart = CFAbsoluteTimeGetCurrent();
  }
}

- (void)endUserWait
{
  @synchronized (self)
  {
    _pausedTime += CFAbsoluteTimeGetCurrent() - _waitStart;
    _waitStart = 0;
  }
}

- (double)elapsedTime
{
  @synchronized (self)
  {
    double t = CFAbsoluteTimeGetCurrent() - _startTime - _pausedTime;
    if (_paused)
      t -= CFAbsoluteTimeGetCurrent() - _pauseStart;
    if (_waitStart != 0)
      t -= CFAbsoluteTimeGetCurrent() - _waitStart;
    return t;
  }
}

- (SZProgressSnapshot)snapshot
{
  os_unfair_lock_lock(&_lock);
  SZProgressSnapshot s = _state;
  os_unfair_lock_unlock(&_lock);
  return s;
}

- (NSString *)currentFileName
{
  os_unfair_lock_lock(&_lock);
  NSString *s = _currentName;
  os_unfair_lock_unlock(&_lock);
  return s;
}

- (NSArray<NSString *> *)messages
{
  os_unfair_lock_lock(&_lock);
  NSArray *a = [_messages copy];
  os_unfair_lock_unlock(&_lock);
  return a;
}

- (BOOL)hasErrors
{
  return [self snapshot].NumErrors != 0;
}

- (void)addMessage:(NSString *)message isError:(BOOL)isError
{
  os_unfair_lock_lock(&_lock);
  [_messages addObject:message];
  if (isError)
    _state.NumErrors++;
  os_unfair_lock_unlock(&_lock);
}

@end


@implementation SZArchiveNode

- (instancetype)init
{
  self = [super init];
  if (self)
  {
    _children = [NSMutableArray array];
    _itemIndex = -1;
    _name = @"";
    _method = @"";
  }
  return self;
}

- (NSString *)pathInArchive
{
  if (!_parent)
    return @"";
  NSString *p = [_parent pathInArchive];
  return p.length ? [NSString stringWithFormat:@"%@/%@", p, _name] : _name;
}

- (NSString *)folderPrefix
{
  NSString *p = [self pathInArchive];
  return p.length ? [p stringByAppendingString:@"/"] : @"";
}

- (void)collectItemIndices:(NSMutableIndexSet *)indices
{
  if (_itemIndex >= 0)
    [indices addIndex:(NSUInteger)_itemIndex];
  for (SZArchiveNode *c in _children)
    [c collectItemIndices:indices];
}

- (SZArchiveNode *)childWithName:(NSString *)name
{
  for (SZArchiveNode *c in _children)
    if ([c.name isEqualToString:name])
      return c;
  return nil;
}

- (SZArchiveNode *)nodeAtPath:(NSString *)path
{
  SZArchiveNode *n = self;
  for (NSString *part in [path componentsSeparatedByString:@"/"])
  {
    if (part.length == 0)
      continue;
    n = [n childWithName:part];
    if (!n)
      return nil;
  }
  return n;
}

@end


@implementation SZArchive
{
  IArchive *_arc;
  BOOL _canUpdate;
}

static void SumFolder(SZArchiveNode *node)
{
  if (!node.isDir)
    return;
  uint64_t size = 0, packSize = 0, numFiles = 0, numFolders = 0;
  bool packDefined = false;
  for (SZArchiveNode *c in node.children)
  {
    if (c.isDir)
    {
      SumFolder(c);
      numFolders += 1 + c.numFolders;
      numFiles += c.numFiles;
    }
    else
      numFiles++;
    size += c.size;
    if (c.packSizeDefined)
    {
      packSize += c.packSize;
      packDefined = true;
    }
  }
  node.size = size;
  node.sizeDefined = YES;
  if (packDefined)
  {
    node.packSize = packSize;
    node.packSizeDefined = YES;
  }
  node.numFiles = numFiles;
  node.numFolders = numFolders;
}

- (instancetype)initWithEngineArchive:(IArchive *)arc path:(NSString *)path
{
  self = [super init];
  if (self)
  {
    _arc = arc;
    _path = [path copy];
    _displayName = [[path lastPathComponent] copy];
    _canUpdate = arc->CanUpdate();
    _formatName = SZString(arc->GetFormatName());
    _root = [[SZArchiveNode alloc] init];
    _root.isDir = YES;
    [self buildTree];
  }
  return self;
}

- (void)dealloc
{
  delete _arc;
}

- (IArchive *)engineArchive
{
  return _arc;
}

// nested archives (archive inside archive) are opened from temp files, so we don't update them
- (BOOL)canUpdate
{
  return _canUpdate && _parentArchive == nil;
}

- (void)buildTree
{
  const unsigned num = _arc->GetNumItems();
  // dictionary for fast search of folders: "dir/sub" -> node
  NSMutableDictionary<NSString *, SZArchiveNode *> *dirs = [NSMutableDictionary dictionary];
  dirs[@""] = _root;

  for (unsigned i = 0; i < num; i++)
  {
    const CItemInfo &item = _arc->GetItem(i);
    NSString *path = SZString(item.Path);
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *p in parts)
      if (p.length && ![p isEqualToString:@"."])
        [clean addObject:p];
    if (clean.count == 0)
      [clean addObject:@"[no name]"];

    SZArchiveNode *parent = _root;
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger k = 0; k + 1 < clean.count; k++)
    {
      if (k)
        [cur appendString:@"/"];
      [cur appendString:clean[k]];
      SZArchiveNode *d = dirs[cur];
      if (!d)
      {
        d = [[SZArchiveNode alloc] init];
        d.name = clean[k];
        d.isDir = YES;
        d.parent = parent;
        [parent.children addObject:d];
        dirs[[cur copy]] = d;
      }
      parent = d;
    }

    NSString *name = clean.lastObject;
    SZArchiveNode *node = nil;
    if (item.IsDir)
    {
      NSString *key = cur.length ? [NSString stringWithFormat:@"%@/%@", cur, name] : name;
      node = dirs[key];
      if (!node)
      {
        node = [[SZArchiveNode alloc] init];
        node.name = name;
        node.isDir = YES;
        node.parent = parent;
        [parent.children addObject:node];
        dirs[key] = node;
      }
    }
    else
    {
      node = [[SZArchiveNode alloc] init];
      node.name = name;
      node.parent = parent;
      [parent.children addObject:node];
    }
    node.itemIndex = (NSInteger)i;
    node.sizeDefined = item.SizeDefined;
    node.size = item.Size;
    node.packSizeDefined = item.PackSizeDefined;
    node.packSize = item.PackSize;
    node.crcDefined = item.CrcDefined;
    node.crc = item.Crc;
    node.encrypted = item.Encrypted;
    node.attrib = item.Attrib;
    node.attribDefined = item.AttribDefined;
    node.method = SZString(item.Method);
    if (item.MTimeDefined)
      node.mtime = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)item.MTime];
  }
  SumFolder(_root);
}

@end


NSString *SZResultMessage(const CResult &r)
{
  if (r.HResult == 0)
    return @"";
  return SZString(GetErrorMessage(r.HResult));
}
