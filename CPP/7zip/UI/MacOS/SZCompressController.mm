// SZCompressController.mm

#import "SZCompressController.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZUtils.h"

#include "MacEngine.h"

// ---------- formats and methods (same as in GUI/CompressDialog.cpp) ----------

enum EMethodID
{
  kLZMA2,
  kLZMA,
  kPPMd,
  kBZip2,
  kDeflate,
  kDeflate64,
  kCopy,
  kPPMdZip,
  kGnu,
  kPosix
};

static NSString * const kMethodNames[] =
{
  @"LZMA2",
  @"LZMA",
  @"PPMd",
  @"BZip2",
  @"Deflate",
  @"Deflate64",
  @"Copy",
  @"PPMd",
  @"GNU",
  @"POSIX"
};

static const EMethodID g_7zMethods[] = { kLZMA2, kLZMA, kPPMd, kBZip2, kDeflate, kDeflate64, kCopy };
static const EMethodID g_ZipMethods[] = { kDeflate, kDeflate64, kBZip2, kLZMA, kPPMdZip };
static const EMethodID g_GZipMethods[] = { kDeflate };
static const EMethodID g_BZip2Methods[] = { kBZip2 };
static const EMethodID g_XzMethods[] = { kLZMA2 };
static const EMethodID g_TarMethods[] = { kGnu, kPosix };

static const uint32_t kFF_Solid       = 1 << 1;
static const uint32_t kFF_MultiThread = 1 << 2;
static const uint32_t kFF_Encrypt     = 1 << 3;
static const uint32_t kFF_EncryptFileNames = 1 << 4;

struct CFormatDesc
{
  const char *Name;  // name of format in 7-Zip engine
  uint32_t LevelsMask;
  unsigned NumMethods;
  const EMethodID *Methods;
  uint32_t Flags;
};

#define METHODS_PAIR(x) (sizeof(x) / sizeof(x[0])), x

static const CFormatDesc g_Formats[] =
{
  { "7z",    (1 << 10) - 1, METHODS_PAIR(g_7zMethods), kFF_Solid | kFF_MultiThread | kFF_Encrypt | kFF_EncryptFileNames },
  { "bzip2", (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9), METHODS_PAIR(g_BZip2Methods), kFF_MultiThread },
  { "gzip",  (1 << 1) | (1 << 5) | (1 << 7) | (1 << 9), METHODS_PAIR(g_GZipMethods), 0 },
  { "tar",   (1 << 0), METHODS_PAIR(g_TarMethods), 0 },
  { "wim",   (1 << 0), 0, NULL, 0 },
  { "xz",    (1 << 10) - 1 - (1 << 0), METHODS_PAIR(g_XzMethods), kFF_Solid | kFF_MultiThread },
  { "zip",   (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9), METHODS_PAIR(g_ZipMethods), kFF_MultiThread | kFF_Encrypt },
};

static const unsigned kNumFormats = sizeof(g_Formats) / sizeof(g_Formats[0]);

static const uint32_t kLevels[] = { 0, 1, 3, 5, 7, 9 };

static NSString *LevelName(uint32_t level)
{
  switch (level)
  {
    case 0: return SZLang(kLang_MethodStore, @"Store");
    case 1: return SZLang(kLang_MethodFastest, @"Fastest");
    case 3: return SZLang(kLang_MethodFast, @"Fast");
    case 5: return SZLang(kLang_MethodNormal, @"Normal");
    case 7: return SZLang(kLang_MethodMaximum, @"Maximum");
    case 9: return SZLang(kLang_MethodUltra, @"Ultra");
  }
  return [NSString stringWithFormat:@"%u", level];
}

static NSString *SizeString(uint64_t v)
{
  if (v == 0)
    return @"0";
  if ((v & ((1ull << 30) - 1)) == 0) return [NSString stringWithFormat:@"%llu GB", v >> 30];
  if ((v & ((1ull << 20) - 1)) == 0) return [NSString stringWithFormat:@"%llu MB", v >> 20];
  if ((v & ((1ull << 10) - 1)) == 0) return [NSString stringWithFormat:@"%llu KB", v >> 10];
  return [NSString stringWithFormat:@"%llu B", v];
}

static NSString *AutoString(NSString *value)
{
  return value ? [NSString stringWithFormat:@"Auto (%@)", value] : @"Auto";
}

static NSString *FileName(NSString *path)
{
  return path.lastPathComponent;
}


@implementation SZCompressRequest
@end


static NSString * const kKey_Format = @"Compress.Format";
static NSString * const kKey_LevelPrefix = @"Compress.Level.";
static NSString * const kKey_MethodPrefix = @"Compress.Method.";
static NSString * const kKey_EncryptNames = @"Compress.EncryptNames";

static NSMutableSet *g_OpenControllers;


@interface SZCompressController () <NSWindowDelegate, NSComboBoxDelegate>
@property (copy) void (^completion)(SZCompressRequest *);
@property (copy) NSArray<NSString *> *files;
@end

@implementation SZCompressController
{
  NSTextField *_archiveField;
  NSPopUpButton *_formatPopup;
  NSPopUpButton *_levelPopup;
  NSPopUpButton *_methodPopup;
  NSPopUpButton *_dictPopup;
  NSPopUpButton *_orderPopup;
  NSPopUpButton *_solidPopup;
  NSPopUpButton *_threadsPopup;
  NSComboBox *_volumesCombo;
  NSTextField *_paramsField;
  NSPopUpButton *_updatePopup;
  NSPopUpButton *_pathModePopup;
  NSButton *_deleteAfterCheck;
  NSButton *_symLinksCheck;
  NSSecureTextField *_password1;
  NSSecureTextField *_password2;
  NSTextField *_passwordPlain;
  NSButton *_showPasswordCheck;
  NSPopUpButton *_encMethodPopup;
  NSButton *_encryptNamesCheck;
  NSTextField *_orderLabel;
  NSTextField *_dictLabel;
  NSTextField *_reenterLabel;

  NSMutableArray<NSNumber *> *_formatIndices; // index in g_Formats for each item in popup
  uint32_t _numHardwareThreads;
}

+ (NSString *)defaultArchivePathForFiles:(NSArray<NSString *> *)files extension:(NSString *)ext
{
  NSString *first = files.firstObject;
  NSString *dir = [first stringByDeletingLastPathComponent];
  NSString *name;
  if (files.count == 1)
  {
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:first isDirectory:&isDir];
    name = isDir ? first.lastPathComponent : [first.lastPathComponent stringByDeletingPathExtension];
    if (name.length == 0)
      name = first.lastPathComponent;
  }
  else
  {
    name = dir.lastPathComponent;
    if (name.length == 0 || [name isEqualToString:@"/"])
      name = @"Archive";
  }
  return [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
}

+ (NSArray<NSString *> *)quickArgsForFiles:(NSArray<NSString *> *)files archivePath:(NSString *)archivePath format:(NSString *)format
{
  NSMutableArray *a = [NSMutableArray arrayWithObjects:@"a", [@"-t" stringByAppendingString:format], @"-spd", @"-snl", @"--", archivePath, nil];
  [a addObjectsFromArray:files];
  return a;
}

+ (void)showForFiles:(NSArray<NSString *> *)files
         archivePath:(NSString *)archivePath
              parent:(NSWindow *)parent
          completion:(void (^)(SZCompressRequest *request))completion
{
  SZCompressController *c = [[SZCompressController alloc] initWithFiles:files archivePath:archivePath];
  c.completion = completion;
  if (!g_OpenControllers)
    g_OpenControllers = [NSMutableSet set];
  [g_OpenControllers addObject:c];
  if (parent && parent.isVisible && !parent.attachedSheet)
    [parent beginSheet:c.window completionHandler:nil];
  else
  {
    [c.window center];
    [c.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
  }
}

static NSTextField *RowLabel(uint32_t langID, NSString *s)
{
  NSTextField *t = SZLabel(SZStripAmp(SZLang(langID, s)));
  [t setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  return t;
}

static NSBox *GroupBox(NSString *title, NSView *content)
{
  NSBox *box = [[NSBox alloc] init];
  box.title = title;
  box.contentViewMargins = NSMakeSize(10, 10);
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [box.contentView addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:8],
    [content.trailingAnchor constraintLessThanOrEqualToAnchor:box.contentView.trailingAnchor constant:-8],
    [content.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:6],
    [content.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-8],
  ]];
  // NSBox positions its contentView without constraints,
  // so we set minimal size of box for autolayout here
  const NSSize fs = content.fittingSize;
  [box.widthAnchor constraintGreaterThanOrEqualToConstant:fs.width + 40].active = YES;
  [box.heightAnchor constraintGreaterThanOrEqualToConstant:fs.height + 44].active = YES;
  return box;
}

- (BOOL)isSingleFile
{
  if (_files.count != 1)
    return NO;
  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:_files[0] isDirectory:&isDir];
  return !isDir;
}

- (instancetype)initWithFiles:(NSArray<NSString *> *)files archivePath:(NSString *)archivePath
{
  NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 760, 480)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
      backing:NSBackingStoreBuffered defer:YES];
  w.releasedWhenClosed = NO;
  w.title = SZStripAmp(SZLang(kLang_AddToArchive, @"Add to Archive"));
  self = [super initWithWindow:w];
  if (!self)
    return nil;
  w.delegate = self;
  _files = [files copy];
  _numHardwareThreads = (uint32_t)[[NSProcessInfo processInfo] activeProcessorCount];
  if (_numHardwareThreads == 0)
    _numHardwareThreads = 1;

  // ---- archive ----
  NSTextField *archiveLabel = RowLabel(kLang_CompressArchive, @"Archive:");
  _archiveField = [[NSTextField alloc] init];
  _archiveField.stringValue = archivePath;
  _archiveField.lineBreakMode = NSLineBreakByTruncatingHead;
  NSButton *browse = SZPushButton(@"…", self, @selector(browse:));
  NSStackView *archiveRow = [NSStackView stackViewWithViews:@[_archiveField, browse]];
  [_archiveField setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

  // ---- left column ----
  _formatIndices = [NSMutableArray array];
  _formatPopup = SZPopUp(@[]);
  const BOOL singleFile = [self isSingleFile];
  for (unsigned i = 0; i < kNumFormats; i++)
  {
    const int fi = NMacEngine::FindFormatForExtension(g_Formats[i].Name);
    if (fi < 0)
      continue;
    NMacEngine::CFormatInfo info;
    NMacEngine::GetFormatInfo((unsigned)fi, info);
    if (!info.CanUpdate)
      continue;
    if (info.KeepName && !singleFile)
      continue;
    [_formatPopup addItemWithTitle:SZString(g_Formats[i].Name)];
    [_formatIndices addObject:@(i)];
  }
  _formatPopup.target = self;
  _formatPopup.action = @selector(formatChanged:);

  _levelPopup = SZPopUp(@[]);
  _levelPopup.target = self;
  _levelPopup.action = @selector(levelChanged:);
  _methodPopup = SZPopUp(@[]);
  _methodPopup.target = self;
  _methodPopup.action = @selector(methodChanged:);
  _dictPopup = SZPopUp(@[]);
  _dictPopup.target = self;
  _dictPopup.action = @selector(dictChanged:);
  _orderPopup = SZPopUp(@[]);
  _solidPopup = SZPopUp(@[]);
  _threadsPopup = SZPopUp(@[]);
  NSTextField *threadsMax = SZSecondaryLabel([NSString stringWithFormat:@"/ %u", _numHardwareThreads]);
  NSStackView *threadsRow = [NSStackView stackViewWithViews:@[_threadsPopup, threadsMax]];

  _volumesCombo = [[NSComboBox alloc] init];
  [_volumesCombo addItemsWithObjectValues:@[@"10M", @"100M", @"1000M", @"650M - CD", @"700M - CD",
      @"4092M - FAT", @"4480M - DVD", @"8128M - DVD DL", @"23040M - BD"]];
  _volumesCombo.placeholderString = @"";
  _paramsField = [[NSTextField alloc] init];
  _paramsField.placeholderString = @"x=9 mt=4";

  _dictLabel = RowLabel(kLang_CompressDictionary, @"Dictionary size:");
  _orderLabel = RowLabel(kLang_CompressOrder, @"Word size:");

  NSGridView *left = [NSGridView gridViewWithViews:@[
    @[RowLabel(kLang_CompressFormat, @"Archive format:"), _formatPopup],
    @[RowLabel(kLang_CompressLevel, @"Compression level:"), _levelPopup],
    @[RowLabel(kLang_CompressMethod, @"Compression method:"), _methodPopup],
    @[_dictLabel, _dictPopup],
    @[_orderLabel, _orderPopup],
    @[RowLabel(kLang_CompressSolid, @"Solid Block size:"), _solidPopup],
    @[RowLabel(kLang_CompressThreads, @"Number of CPU threads:"), threadsRow],
    @[SZSeparator(), [NSGridCell emptyContentView]],
    @[RowLabel(kLang_SplitToVolumes, @"Split to volumes, bytes:"), _volumesCombo],
    @[RowLabel(kLang_CompressParameters, @"Parameters:"), _paramsField],
  ]];
  left.rowSpacing = 8;
  left.columnSpacing = 8;
  [left columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  for (NSInteger i = 0; i < left.numberOfRows; i++)
    [left rowAtIndex:i].yPlacement = NSGridCellPlacementCenter;
  [left rowAtIndex:7].height = 8;
  [[left cellAtColumnIndex:0 rowIndex:7] setXPlacement:NSGridCellPlacementFill];
  [left mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(7, 1)];
  for (NSView *v in @[_formatPopup, _levelPopup, _methodPopup, _dictPopup, _orderPopup, _solidPopup, _volumesCombo, _paramsField])
    [v.widthAnchor constraintEqualToConstant:170].active = YES;
  [_threadsPopup.widthAnchor constraintEqualToConstant:120].active = YES;
  SZHug(left);

  // ---- right column ----
  _updatePopup = SZPopUp(@[
    SZLang(kLang_UpdateModeAdd, @"Add and replace files"),
    SZLang(kLang_UpdateModeUpdate, @"Update and add files"),
    SZLang(kLang_UpdateModeFresh, @"Freshen existing files"),
    SZLang(kLang_UpdateModeSync, @"Synchronize files")
  ]);
  _pathModePopup = SZPopUp(@[
    SZLang(kLang_PathsRelative, @"Relative pathnames"),
    SZLang(kLang_PathsFull, @"Full pathnames"),
    SZLang(kLang_PathsAbs, @"Absolute pathnames")
  ]);
  NSGridView *modes = [NSGridView gridViewWithViews:@[
    @[RowLabel(kLang_CompressUpdateMode, @"Update mode:"), _updatePopup],
    @[RowLabel(kLang_PathMode, @"Path mode:"), _pathModePopup],
  ]];
  modes.rowSpacing = 8;
  [modes columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [modes rowAtIndex:0].yPlacement = NSGridCellPlacementCenter;
  [modes rowAtIndex:1].yPlacement = NSGridCellPlacementCenter;
  SZHug(modes);
  [_updatePopup.widthAnchor constraintEqualToConstant:200].active = YES;
  [_pathModePopup.widthAnchor constraintEqualToConstant:200].active = YES;

  _deleteAfterCheck = SZCheckbox(SZStripAmp(SZLang(kLang_CompressDeleteAfter, @"Delete files after compression")), NO);
  _symLinksCheck = SZCheckbox(SZStripAmp(SZLang(kLang_CompressNtSymLinks, @"Store symbolic links")), YES);
  NSStackView *optionsStack = [NSStackView stackViewWithViews:@[_symLinksCheck, _deleteAfterCheck]];
  optionsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  optionsStack.alignment = NSLayoutAttributeLeading;
  NSBox *optionsBox = GroupBox(SZStripAmp(SZLang(kLang_CompressOptionsGroup, @"Options")), optionsStack);

  _password1 = [[NSSecureTextField alloc] init];
  _password2 = [[NSSecureTextField alloc] init];
  _passwordPlain = [[NSTextField alloc] init];
  _passwordPlain.hidden = YES;
  _showPasswordCheck = SZCheckbox(SZStripAmp(SZLang(kLang_PasswordShow, @"Show Password")), NO);
  _showPasswordCheck.target = self;
  _showPasswordCheck.action = @selector(showPasswordToggled:);
  _encMethodPopup = SZPopUp(@[]);
  _encryptNamesCheck = SZCheckbox(SZStripAmp(SZLang(kLang_CompressEncryptFileNames, @"Encrypt file names")),
      [[NSUserDefaults standardUserDefaults] boolForKey:kKey_EncryptNames]);
  _reenterLabel = SZLabel(SZStripAmp(SZLang(kLang_PasswordReenter, @"Reenter password:")));
  [_reenterLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  for (NSView *v in @[_password1, _password2, _passwordPlain])
    [v.widthAnchor constraintEqualToConstant:200].active = YES;
  NSStackView *pwStack = [NSStackView stackViewWithViews:@[_password1, _passwordPlain]];
  NSGridView *enc = [NSGridView gridViewWithViews:@[
    @[SZLabel(SZStripAmp(SZLang(kLang_PasswordEnter, @"Enter password:"))), pwStack],
    @[_reenterLabel, _password2],
    @[[NSGridCell emptyContentView], _showPasswordCheck],
    @[SZLabel(SZStripAmp(SZLang(kLang_CompressEncryptionMethod, @"Encryption method:"))), _encMethodPopup],
    @[[NSGridCell emptyContentView], _encryptNamesCheck],
  ]];
  enc.rowSpacing = 8;
  [enc columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  for (NSInteger i = 0; i < enc.numberOfRows; i++)
    [enc rowAtIndex:i].yPlacement = NSGridCellPlacementCenter;
  SZHug(enc);
  NSBox *encBox = GroupBox(SZStripAmp(SZLang(kLang_CompressEncryption, @"Encryption")), enc);

  NSStackView *right = [NSStackView stackViewWithViews:@[modes, optionsBox, encBox]];
  right.orientation = NSUserInterfaceLayoutOrientationVertical;
  right.alignment = NSLayoutAttributeLeading;
  right.spacing = 12;
  [optionsBox.widthAnchor constraintEqualToAnchor:right.widthAnchor].active = YES;
  [encBox.widthAnchor constraintEqualToAnchor:right.widthAnchor].active = YES;

  NSStackView *columns = [NSStackView stackViewWithViews:@[left, right]];
  columns.alignment = NSLayoutAttributeTop;
  columns.spacing = 24;
  columns.distribution = NSStackViewDistributionFill;
  [right setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [left setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

  // ---- buttons ----
  NSButton *ok = SZPushButton(SZLang(kLang_OK, @"OK"), self, @selector(okClicked:));
  ok.keyEquivalent = @"\r";
  NSButton *cancel = SZPushButton(SZLang(kLang_Cancel, @"Cancel"), self, @selector(cancelClicked:));
  cancel.keyEquivalent = @"\033";
  [ok.widthAnchor constraintGreaterThanOrEqualToConstant:90].active = YES;
  [cancel.widthAnchor constraintGreaterThanOrEqualToConstant:90].active = YES;
  NSView *spacer = [[NSView alloc] init];
  [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSTextField *filesInfo = SZSecondaryLabel(_files.count == 1 ? FileName(_files[0]) :
      SZLangFormat(kLang_NSelectedItems, @"{0} object(s) selected", [NSString stringWithFormat:@"%lu", (unsigned long)_files.count]));
  NSStackView *buttons = [NSStackView stackViewWithViews:@[filesInfo, spacer, cancel, ok]];

  NSStackView *main = [NSStackView stackViewWithViews:@[archiveLabel, archiveRow, SZSeparator(), columns, buttons]];
  main.orientation = NSUserInterfaceLayoutOrientationVertical;
  main.alignment = NSLayoutAttributeLeading;
  main.spacing = 12;
  [main setCustomSpacing:4 afterView:archiveLabel];
  [main setCustomSpacing:18 afterView:columns];
  main.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
  main.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *content = w.contentView;
  [content addSubview:main];
  [NSLayoutConstraint activateConstraints:@[
    [main.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [main.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [main.topAnchor constraintEqualToAnchor:content.topAnchor],
    [main.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [content.widthAnchor constraintGreaterThanOrEqualToConstant:780],
    [archiveRow.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-40],
    [columns.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-40],
    [main.arrangedSubviews[2].widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-40],
    [buttons.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-40],
  ]];

  // select format: from archive extension or from last used format
  NSString *ext = [[archivePath pathExtension] lowercaseString];
  NSString *lastFormat = [[NSUserDefaults standardUserDefaults] stringForKey:kKey_Format] ?: @"7z";
  NSInteger sel = -1;
  for (NSUInteger i = 0; i < _formatIndices.count; i++)
  {
    NSString *name = SZString(g_Formats[_formatIndices[i].unsignedIntValue].Name);
    if ([name isEqualToString:ext] || ([ext isEqualToString:@"gz"] && [name isEqualToString:@"gzip"])
        || ([ext isEqualToString:@"bz2"] && [name isEqualToString:@"bzip2"]))
      sel = (NSInteger)i;
  }
  if (sel < 0)
    for (NSUInteger i = 0; i < _formatIndices.count; i++)
      if ([SZString(g_Formats[_formatIndices[i].unsignedIntValue].Name) isEqualToString:lastFormat])
        sel = (NSInteger)i;
  if (sel < 0)
    sel = 0;
  [_formatPopup selectItemAtIndex:sel];
  [self formatChanged:nil];
  SZFitWindow(w, main);
  w.initialFirstResponder = ok;
  return self;
}

// ---------- state ----------

- (const CFormatDesc &)format
{
  NSInteger i = _formatPopup.indexOfSelectedItem;
  if (i < 0)
    i = 0;
  return g_Formats[_formatIndices[(NSUInteger)i].unsignedIntValue];
}

- (NSString *)formatName
{
  return SZString([self format].Name);
}

- (BOOL)is7z
{
  return [[self formatName] isEqualToString:@"7z"];
}

- (uint32_t)level
{
  return (uint32_t)_levelPopup.selectedTag;
}

- (int)methodID
{
  if (_methodPopup.numberOfItems == 0 || !_methodPopup.enabled)
    return -1;
  return (int)_methodPopup.selectedTag;
}

// ---------- updating of controls ----------

- (void)formatChanged:(id)sender
{
  const CFormatDesc &f = [self format];
  NSString *name = [self formatName];
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

  // levels
  [_levelPopup removeAllItems];
  NSInteger savedLevel = [d objectForKey:[kKey_LevelPrefix stringByAppendingString:name]] ?
      [d integerForKey:[kKey_LevelPrefix stringByAppendingString:name]] : 5;
  NSInteger selIndex = -1;
  for (unsigned i = 0; i < sizeof(kLevels) / sizeof(kLevels[0]); i++)
  {
    const uint32_t l = kLevels[i];
    if ((f.LevelsMask & (1u << l)) == 0)
      continue;
    [_levelPopup addItemWithTitle:LevelName(l)];
    _levelPopup.lastItem.tag = l;
    if ((NSInteger)l <= savedLevel)
      selIndex = _levelPopup.numberOfItems - 1;
  }
  if (selIndex < 0)
    selIndex = 0;
  [_levelPopup selectItemAtIndex:selIndex];
  _levelPopup.enabled = (_levelPopup.numberOfItems > 1);

  // encryption
  [_encMethodPopup removeAllItems];
  const BOOL encrypt = (f.Flags & kFF_Encrypt) != 0;
  if ([name isEqualToString:@"zip"])
  {
    [_encMethodPopup addItemsWithTitles:@[@"ZipCrypto", @"AES-256"]];
  }
  else if (encrypt)
    [_encMethodPopup addItemWithTitle:@"AES-256"];
  _encMethodPopup.enabled = (_encMethodPopup.numberOfItems > 1);
  for (NSControl *c in @[_password1, _password2, _passwordPlain, _showPasswordCheck])
    c.enabled = encrypt;
  _encryptNamesCheck.enabled = (f.Flags & kFF_EncryptFileNames) != 0;

  _threadsPopup.enabled = (f.Flags & kFF_MultiThread) != 0;

  // archive name extension
  NSString *path = _archiveField.stringValue;
  if (path.length && sender)
  {
    NSString *newExt = name;
    if ([name isEqualToString:@"gzip"]) newExt = @"gz";
    else if ([name isEqualToString:@"bzip2"]) newExt = @"bz2";
    NSString *oldExt = [path pathExtension].lowercaseString;
    BOOL knownExt = NO;
    for (unsigned i = 0; i < kNumFormats; i++)
    {
      NSString *n = SZString(g_Formats[i].Name);
      if ([n isEqualToString:oldExt] || [oldExt isEqualToString:@"gz"] || [oldExt isEqualToString:@"bz2"])
        knownExt = YES;
    }
    if (knownExt)
      path = [path stringByDeletingPathExtension];
    // for single file in gzip/bzip2/xz we keep original extension: "file.txt.gz"
    _archiveField.stringValue = [path stringByAppendingPathExtension:newExt];
  }

  [self levelChanged:nil];
}

- (void)levelChanged:(id)sender
{
  const CFormatDesc &f = [self format];
  NSString *name = [self formatName];
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  const uint32_t level = [self level];

  // methods
  NSString *savedMethod = [d stringForKey:[kKey_MethodPrefix stringByAppendingString:name]];
  NSInteger prevMethod = (sender && _methodPopup.numberOfItems) ? _methodPopup.selectedTag : -1;
  [_methodPopup removeAllItems];
  for (unsigned i = 0; i < f.NumMethods; i++)
  {
    const EMethodID m = f.Methods[i];
    if (level == 0 && m != kCopy && [self is7z])
      continue;
    if (level != 0 && m == kCopy)
      continue;
    [_methodPopup addItemWithTitle:kMethodNames[m]];
    _methodPopup.lastItem.tag = m;
  }
  if (level == 0 && [self is7z] && _methodPopup.numberOfItems == 0)
  {
    [_methodPopup addItemWithTitle:kMethodNames[kCopy]];
    _methodPopup.lastItem.tag = kCopy;
  }
  if (prevMethod >= 0 && [_methodPopup indexOfItemWithTag:prevMethod] >= 0)
    [_methodPopup selectItemWithTag:prevMethod];
  else if (savedMethod && [_methodPopup itemWithTitle:savedMethod])
    [_methodPopup selectItemWithTitle:savedMethod];
  _methodPopup.enabled = (_methodPopup.numberOfItems > 1);

  [self methodChanged:nil];
}

- (void)methodChanged:(id)sender
{
  const int m = [self methodID] >= 0 ? [self methodID] : (_methodPopup.numberOfItems ? (int)_methodPopup.selectedTag : -1);
  const uint32_t level = [self level];

  // dictionary
  [_dictPopup removeAllItems];
  const uint64_t autoDict = (m >= 0) ? [self autoDictForMethod:m] : 0;
  [_dictPopup addItemWithTitle:AutoString(autoDict ? SizeString(autoDict) : nil)];
  _dictPopup.lastItem.tag = 0;
  NSMutableArray<NSNumber *> *dicts = [NSMutableArray array];
  switch (m)
  {
    case kLZMA:
    case kLZMA2:
      [dicts addObject:@(64 << 10)];
      [dicts addObject:@(256 << 10)];
      for (unsigned i = (20 - 1) * 2; i <= (31 - 1) * 2 + 1; i++)
      {
        if (i == (20 - 1) * 2 + 1)
          continue;
        const uint64_t dict = (uint64_t)(2 + (i & 1)) << (i / 2);
        if (dict > ((uint64_t)3 << 29))
          break;
        [dicts addObject:@(dict)];
      }
      break;
    case kPPMd:
      for (unsigned i = (20 - 1) * 2; i <= (30 - 1) * 2; i++)
      {
        if (i == (20 - 1) * 2 + 1)
          continue;
        [dicts addObject:@((uint64_t)(2 + (i & 1)) << (i / 2))];
      }
      break;
    case kPPMdZip:
      for (unsigned i = 20; i <= 28; i++)
        [dicts addObject:@((uint64_t)1 << i)];
      break;
    case kBZip2:
      for (unsigned i = 1; i <= 9; i++)
        [dicts addObject:@((uint64_t)(i * 100) << 10)];
      break;
  }
  for (NSNumber *n in dicts)
  {
    [_dictPopup addItemWithTitle:SizeString(n.unsignedLongLongValue)];
    _dictPopup.lastItem.tag = (NSInteger)n.unsignedLongLongValue;
  }
  _dictPopup.enabled = (dicts.count > 0) && level != 0;

  // word size / order
  [_orderPopup removeAllItems];
  const uint32_t autoOrder = (m >= 0) ? [self autoOrderForMethod:m] : 0;
  [_orderPopup addItemWithTitle:AutoString(autoOrder ? [NSString stringWithFormat:@"%u", autoOrder] : nil)];
  _orderPopup.lastItem.tag = 0;
  NSMutableArray<NSNumber *> *orders = [NSMutableArray array];
  switch (m)
  {
    case kLZMA:
    case kLZMA2:
    case kDeflate:
    case kDeflate64:
      for (unsigned i = 2 * 2; i < 8 * 2; i++)
      {
        uint32_t order = (uint32_t)(2 + (i & 1)) << (i / 2);
        if (order > 256)
          order = (m == kDeflate) ? 258 : (m == kDeflate64) ? 257 : 273;
        [orders addObject:@(order)];
      }
      break;
    case kPPMd:
      for (unsigned i = 0;; i++)
      {
        uint32_t order = i + 2;
        if (i >= 2)
          order = (4 + ((i - 2) & 3)) << ((i - 2) / 4);
        [orders addObject:@(order)];
        if (order >= 32)
          break;
      }
      break;
    case kPPMdZip:
      for (uint32_t i = 2; i <= 16; i++)
        [orders addObject:@(i)];
      break;
  }
  for (NSNumber *n in orders)
  {
    [_orderPopup addItemWithTitle:n.stringValue];
    _orderPopup.lastItem.tag = n.integerValue;
  }
  _orderPopup.enabled = (orders.count > 0) && level != 0;

  [self dictChanged:nil];
}

- (uint64_t)autoDictForMethod:(int)m
{
  const uint32_t level = [self level];
  switch (m)
  {
    case kLZMA:
    case kLZMA2:
      return level <= 4 ? ((uint64_t)1 << (level * 2 + 16)) :
             level <= 8 ? ((uint64_t)1 << (level + 20)) : ((uint64_t)1 << 28);
    case kPPMd:
    case kPPMdZip:
      return (uint64_t)1 << (level + 19);
    case kDeflate:
      return 1 << 15;
    case kDeflate64:
      return 1 << 16;
    case kBZip2:
      return level >= 5 ? (900 << 10) : level >= 3 ? (500 << 10) : (100 << 10);
  }
  return 0;
}

- (uint32_t)autoOrderForMethod:(int)m
{
  const uint32_t level = [self level];
  switch (m)
  {
    case kLZMA:
    case kLZMA2:
      return level < 7 ? 32 : 64;
    case kDeflate:
    case kDeflate64:
      return level >= 9 ? 128 : level >= 7 ? 64 : 32;
    case kPPMd:
      return level >= 9 ? 32 : level >= 7 ? 16 : level >= 5 ? 6 : 4;
    case kPPMdZip:
      return level + 3;
  }
  return 0;
}

- (void)dictChanged:(id)sender
{
  const CFormatDesc &f = [self format];
  const uint32_t level = [self level];

  // solid block size
  [_solidPopup removeAllItems];
  [_solidPopup addItemWithTitle:AutoString(nil)];
  _solidPopup.lastItem.tag = -1;
  if ((f.Flags & kFF_Solid) != 0 && level != 0)
  {
    if ([self is7z])
    {
      [_solidPopup addItemWithTitle:SZLang(kLang_NonSolid, @"Non-solid")];
      _solidPopup.lastItem.tag = 0;
    }
    for (unsigned i = 20; i <= 36; i++)
    {
      [_solidPopup addItemWithTitle:SizeString((uint64_t)1 << i)];
      _solidPopup.lastItem.tag = (NSInteger)((uint64_t)1 << i);
    }
    if ([self is7z])
    {
      [_solidPopup addItemWithTitle:SZLang(kLang_Solid, @"Solid")];
      _solidPopup.lastItem.tag = -2;
    }
  }
  _solidPopup.enabled = (_solidPopup.numberOfItems > 1);

  // threads
  [_threadsPopup removeAllItems];
  [_threadsPopup addItemWithTitle:AutoString([NSString stringWithFormat:@"%u", _numHardwareThreads])];
  _threadsPopup.lastItem.tag = 0;
  if ((f.Flags & kFF_MultiThread) != 0)
  {
    const uint32_t maxThreads = _numHardwareThreads * 2;
    for (uint32_t i = 1; i <= maxThreads; i++)
    {
      [_threadsPopup addItemWithTitle:[NSString stringWithFormat:@"%u", i]];
      _threadsPopup.lastItem.tag = i;
    }
  }
}

- (void)showPasswordToggled:(id)sender
{
  const BOOL show = (_showPasswordCheck.state == NSControlStateValueOn);
  if (show)
    _passwordPlain.stringValue = _password1.stringValue;
  else
    _password1.stringValue = _passwordPlain.stringValue;
  _passwordPlain.hidden = !show;
  _password1.hidden = show;
  _password2.hidden = show;
  _reenterLabel.hidden = show;
}

- (void)browse:(id)sender
{
  NSSavePanel *p = [NSSavePanel savePanel];
  p.canCreateDirectories = YES;
  NSString *path = [_archiveField.stringValue stringByExpandingTildeInPath];
  p.directoryURL = [NSURL fileURLWithPath:[path stringByDeletingLastPathComponent] isDirectory:YES];
  p.nameFieldStringValue = path.lastPathComponent;
  p.allowsOtherFileTypes = YES;
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK)
      self->_archiveField.stringValue = p.URL.path;
  }];
}

// ---------- result ----------

- (NSString *)password
{
  return (_showPasswordCheck.state == NSControlStateValueOn) ? _passwordPlain.stringValue : _password1.stringValue;
}

static BOOL ParseVolumeSize(NSString *s, NSString **result)
{
  NSString *t = [[s componentsSeparatedByString:@" "].firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (t.length == 0)
  {
    *result = nil;
    return YES;
  }
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+[bBkKmMgGtT]?$" options:0 error:nil];
  if ([re numberOfMatchesInString:t options:0 range:NSMakeRange(0, t.length)] != 1)
    return NO;
  *result = t;
  return YES;
}

- (void)okClicked:(id)sender
{
  NSString *archivePath = [[_archiveField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] stringByExpandingTildeInPath];
  if (archivePath.length == 0)
  {
    NSBeep();
    return;
  }
  if (![archivePath isAbsolutePath])
    archivePath = [[_files.firstObject stringByDeletingLastPathComponent] stringByAppendingPathComponent:archivePath];

  const CFormatDesc &f = [self format];
  NSString *formatName = [self formatName];
  const BOOL is7z = [self is7z];
  const BOOL isZip = [formatName isEqualToString:@"zip"];
  NSString *password = [self password];

  if (password.length && (f.Flags & kFF_Encrypt))
  {
    if (_showPasswordCheck.state != NSControlStateValueOn && ![_password1.stringValue isEqualToString:_password2.stringValue])
    {
      SZShowAlert(self.window, SZLang(kLang_PasswordNotMatch, @"Passwords do not match"), nil, NSAlertStyleWarning);
      return;
    }
    if (isZip && [_encMethodPopup.titleOfSelectedItem isEqualToString:@"ZipCrypto"]
        && ![password canBeConvertedToEncoding:NSASCIIStringEncoding])
    {
      SZShowAlert(self.window, SZLang(kLang_PasswordUseAscii, @"Use only English letters, numbers and special characters (!, #, $, ...) for password."), nil, NSAlertStyleWarning);
      return;
    }
  }

  NSString *volumes = nil;
  if (!ParseVolumeSize(_volumesCombo.stringValue, &volumes))
  {
    SZShowAlert(self.window, SZLang(kLang_IncorrectVolumeSize, @"Incorrect volume size"), nil, NSAlertStyleWarning);
    return;
  }

  NSMutableArray<NSString *> *a = [NSMutableArray array];
  const NSInteger updateMode = _updatePopup.indexOfSelectedItem;
  [a addObject:(updateMode == 0 ? @"a" : @"u")];
  if (updateMode == 2)
    [a addObject:@"-ur0"];   // freshen
  else if (updateMode == 3)
    [a addObject:@"-uq0"];   // synchronize

  [a addObject:[@"-t" stringByAppendingString:formatName]];
  const uint32_t level = [self level];
  if ((f.LevelsMask & ~1u) != 0 || level != 0)
    [a addObject:[NSString stringWithFormat:@"-mx=%u", level]];

  const int m = [self methodID];
  NSString *prefix = is7z ? @"-m0" : @"-m";
  if (m >= 0 && _methodPopup.numberOfItems > 0)
  {
    const BOOL tarDefault = [formatName isEqualToString:@"tar"] && m == kGnu;
    if (f.NumMethods > 1 && !tarDefault)
      [a addObject:[NSString stringWithFormat:@"%@%@=%@", prefix, is7z ? @"" : @"m", kMethodNames[m]]];
  }
  if (_dictPopup.enabled && _dictPopup.selectedTag > 0)
  {
    const BOOL ppmd = (m == kPPMd || m == kPPMdZip);
    [a addObject:[NSString stringWithFormat:@"%@%@=%lldb", prefix, ppmd ? @"mem" : @"d", (long long)_dictPopup.selectedTag]];
  }
  if (_orderPopup.enabled && _orderPopup.selectedTag > 0)
  {
    const BOOL ppmd = (m == kPPMd || m == kPPMdZip);
    [a addObject:[NSString stringWithFormat:@"%@%@=%ld", prefix, ppmd ? @"o" : @"fb", (long)_orderPopup.selectedTag]];
  }
  if (_solidPopup.enabled)
  {
    const NSInteger s = _solidPopup.selectedTag;
    if (s == 0)
      [a addObject:@"-ms=off"];
    else if (s == -2)
      [a addObject:@"-ms=on"];
    else if (s > 0)
      [a addObject:[NSString stringWithFormat:@"-ms=%lldb", (long long)s]];
  }
  if (_threadsPopup.enabled && _threadsPopup.selectedTag > 0)
    [a addObject:[NSString stringWithFormat:@"-mmt=%ld", (long)_threadsPopup.selectedTag]];

  if (password.length && (f.Flags & kFF_Encrypt))
  {
    [a addObject:[@"-p" stringByAppendingString:password]];
    if (isZip && [_encMethodPopup.titleOfSelectedItem isEqualToString:@"AES-256"])
      [a addObject:@"-mem=AES256"];
    if ((f.Flags & kFF_EncryptFileNames) && _encryptNamesCheck.state == NSControlStateValueOn)
      [a addObject:@"-mhe=on"];
  }

  if (volumes)
    [a addObject:[@"-v" stringByAppendingString:volumes]];

  switch (_pathModePopup.indexOfSelectedItem)
  {
    case 1: [a addObject:@"-spf2"]; break;
    case 2: [a addObject:@"-spf"]; break;
  }
  if (_symLinksCheck.state == NSControlStateValueOn)
    [a addObject:@"-snl"];
  if (_deleteAfterCheck.state == NSControlStateValueOn)
    [a addObject:@"-sdel"];

  // parameters: "x=9 mt=4" -> "-mx=9 -mmt=4", like in Windows version
  for (NSString *p in [_paramsField.stringValue componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])
  {
    if (p.length == 0)
      continue;
    if ([p hasPrefix:@"-"])
      [a addObject:p];
    else
      [a addObject:[@"-m" stringByAppendingString:p]];
  }

  [a addObject:@"-spd"];
  [a addObject:@"--"];
  [a addObject:archivePath];
  [a addObjectsFromArray:_files];

  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setObject:formatName forKey:kKey_Format];
  [d setInteger:level forKey:[kKey_LevelPrefix stringByAppendingString:formatName]];
  if (_methodPopup.numberOfItems > 1)
    [d setObject:_methodPopup.titleOfSelectedItem forKey:[kKey_MethodPrefix stringByAppendingString:formatName]];
  if (_encryptNamesCheck.enabled)
    [d setBool:(_encryptNamesCheck.state == NSControlStateValueOn) forKey:kKey_EncryptNames];

  SZCompressRequest *r = [[SZCompressRequest alloc] init];
  r.archivePath = archivePath;
  r.args = a;
  r.formatName = formatName;
  [self closeWithRequest:r];
}

- (void)closeWithRequest:(SZCompressRequest *)r
{
  if (self.window.sheetParent)
    [self.window.sheetParent endSheet:self.window];
  else
    [self.window orderOut:nil];
  void (^c)(SZCompressRequest *) = _completion;
  _completion = nil;
  [g_OpenControllers removeObject:self];
  if (c)
    c(r);
}

- (void)cancelClicked:(id)sender
{
  [self closeWithRequest:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
  [self closeWithRequest:nil];
  return NO;
}

@end
