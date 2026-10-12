// SZBrowserController.mm

#import "SZBrowserController.h"
#import "SZCommands.h"
#import "SZCompressController.h"
#import "SZEngine.h"
#import "SZExtractController.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZProgressController.h"
#import "SZPrompts.h"
#import "SZPropertiesController.h"
#import "SZUtils.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <vector>

using namespace NMacEngine;

static NSMutableArray<SZBrowserController *> *g_Browsers;

static NSString * const kKey_LastFolder = @"Browser.LastFolder";
static NSString * const kKey_ShowHidden = @"Browser.ShowHidden";
static NSString * const kKey_HiddenColumns = @"Browser.HiddenColumns";

static NSString * const kCol_Name = @"name";
static NSString * const kCol_Size = @"size";
static NSString * const kCol_Packed = @"packed";
static NSString * const kCol_MTime = @"mtime";
static NSString * const kCol_Kind = @"kind";
static NSString * const kCol_Method = @"method";
static NSString * const kCol_Encrypted = @"encrypted";
static NSString * const kCol_CRC = @"crc";
static NSString * const kCol_Attrib = @"attrib";

static NSString * const kTB_Back = @"back";
static NSString * const kTB_Up = @"up";
static NSString * const kTB_Add = @"add";
static NSString * const kTB_Extract = @"extract";
static NSString * const kTB_Test = @"test";
static NSString * const kTB_Delete = @"delete";
static NSString * const kTB_Info = @"info";


// ---------- list item ----------

@interface SZListItem : NSObject
@property (copy) NSString *name;
@property BOOL isDir;
@property (strong, nullable) NSNumber *size;
@property (strong, nullable) NSNumber *packSize;
@property (strong, nullable) NSDate *mtime;
@property (copy, nullable) NSString *kind;
@property (copy, nullable) NSString *method;
@property (copy, nullable) NSString *crc;
@property (copy, nullable) NSString *attrib;
@property BOOL encrypted;
@property (copy, nullable) NSString *fsPath;          // file system mode
@property (strong, nullable) SZArchiveNode *node;     // archive mode
@property (strong, nullable) NSImage *icon;
@end

@implementation SZListItem
@end


// ---------- location for history ----------

@interface SZLocation : NSObject
@property (copy, nullable) NSString *fsPath;
@property (strong, nullable) SZArchive *archive;
@property (copy, nullable) NSString *archiveFolder;
@end

@implementation SZLocation
@end


// ---------- sidebar ----------

@interface SZSidebarItem : NSObject
@property (copy) NSString *title;
@property (copy, nullable) NSString *path;
@property (strong, nullable) NSImage *icon;
@property BOOL isGroup;
@end

@implementation SZSidebarItem
+ (instancetype)group:(NSString *)title
{
  SZSidebarItem *i = [[SZSidebarItem alloc] init];
  i.title = title;
  i.isGroup = YES;
  return i;
}
+ (instancetype)item:(NSString *)title path:(NSString *)path symbol:(NSString *)symbol
{
  SZSidebarItem *i = [[SZSidebarItem alloc] init];
  i.title = title;
  i.path = path;
  i.icon = SZSymbol(symbol, 0);
  return i;
}
@end


// table view that forwards some keys to the controller
@interface SZTableView : NSTableView
@property (weak) id keyHandler;
@end

@implementation SZTableView
- (void)keyDown:(NSEvent *)event
{
  NSString *chars = event.charactersIgnoringModifiers;
  const NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (chars.length == 1)
  {
    const unichar c = [chars characterAtIndex:0];
    if ((c == '\r' || c == 3) && (mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) == 0)
    {
      [NSApp sendAction:@selector(openSelected:) to:_keyHandler from:self];
      return;
    }
    if (c == 127 && (mods & NSEventModifierFlagCommand) == 0)
    {
      // Backspace: go to parent folder, like in Windows version
      [NSApp sendAction:@selector(goUp:) to:_keyHandler from:self];
      return;
    }
  }
  [super keyDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  const NSInteger row = [self rowAtPoint:p];
  if (row >= 0 && ![self isRowSelected:row])
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
  return [super menuForEvent:event];
}
@end


@interface SZBrowserController () <NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSFilePromiseProviderDelegate, NSMenuItemValidation, NSToolbarItemValidation>
@end


@implementation SZBrowserController
{
  // views
  NSSplitViewController *_splitVC;
  NSTableView *_sidebar;
  SZTableView *_table;
  NSPathControl *_pathControl;
  NSTextField *_statusLabel;
  NSTextField *_statusRight;
  NSSegmentedControl *_navControl;

  // state
  NSString *_fsPath;              // current folder (FS mode), or folder of archive (archive mode)
  SZArchive *_archive;            // current archive (archive mode)
  SZArchiveNode *_node;           // current folder in archive
  NSArray<SZListItem *> *_items;
  NSArray<SZSidebarItem *> *_sidebarItems;
  NSMutableArray<SZLocation *> *_back;
  NSMutableArray<SZLocation *> *_forward;
  NSString *_sortKey;
  BOOL _sortAscending;
  BOOL _showHidden;
  NSCache *_iconCache;
  NSOperationQueue *_promiseQueue;
  NSArray<SZLocation *> *_pathTargets;  // location for each item of path control
  BOOL _busy;
}

+ (NSArray<SZBrowserController *> *)allBrowsers
{
  return g_Browsers ? [g_Browsers copy] : @[];
}

+ (SZBrowserController *)openWindowWithPath:(NSString *)path
{
  SZBrowserController *c = [[SZBrowserController alloc] init];
  if (!g_Browsers)
    g_Browsers = [NSMutableArray array];
  [g_Browsers addObject:c];

  NSWindow *key = [NSApp keyWindow];
  if (key && [key.windowController isKindOfClass:[SZBrowserController class]])
  {
    NSPoint p = [c.window cascadeTopLeftFromPoint:NSMakePoint(NSMinX(key.frame), NSMaxY(key.frame))];
    [c.window setFrameTopLeftPoint:p];
  }
  [c showWindow:nil];
  [c.window layoutIfNeeded];
  [c navigateToPath:path];
  return c;
}

- (instancetype)init
{
  NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 620)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
              | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
      backing:NSBackingStoreBuffered defer:YES];
  w.minSize = NSMakeSize(560, 320);
  w.releasedWhenClosed = NO;
  w.tabbingMode = NSWindowTabbingModePreferred;
  w.titlebarAppearsTransparent = NO;
  self = [super initWithWindow:w];
  if (!self)
    return nil;
  w.delegate = self;
  [w setFrameAutosaveName:@"7-Zip Browser"];
  if (!w.frameAutosaveName.length || NSEqualPoints(w.frame.origin, NSZeroPoint))
    [w center];

  _back = [NSMutableArray array];
  _forward = [NSMutableArray array];
  _sortKey = kCol_Name;
  _sortAscending = YES;
  _showHidden = [[NSUserDefaults standardUserDefaults] boolForKey:kKey_ShowHidden];
  _iconCache = [[NSCache alloc] init];
  _promiseQueue = [[NSOperationQueue alloc] init];
  _promiseQueue.maxConcurrentOperationCount = 1;
  _promiseQueue.qualityOfService = NSQualityOfServiceUserInitiated;

  [self buildUI];
  [self buildToolbar];
  return self;
}

// ---------- UI ----------

- (void)buildUI
{
  // sidebar
  _sidebar = [[NSTableView alloc] init];
  NSTableColumn *sc = [[NSTableColumn alloc] initWithIdentifier:@"sidebar"];
  [_sidebar addTableColumn:sc];
  _sidebar.headerView = nil;
  _sidebar.style = NSTableViewStyleSourceList;
  _sidebar.dataSource = self;
  _sidebar.delegate = self;
  _sidebar.rowSizeStyle = NSTableViewRowSizeStyleDefault;
  _sidebar.floatsGroupRows = NO;
  NSScrollView *sideScroll = [[NSScrollView alloc] init];
  sideScroll.documentView = _sidebar;
  sideScroll.drawsBackground = NO;
  sideScroll.hasVerticalScroller = YES;
  NSViewController *sideVC = [[NSViewController alloc] init];
  sideVC.view = sideScroll;
  [self reloadSidebar];

  // list
  _table = [[SZTableView alloc] init];
  _table.keyHandler = self;
  _table.dataSource = self;
  _table.delegate = self;
  _table.allowsMultipleSelection = YES;
  _table.allowsColumnReordering = YES;
  _table.allowsColumnResizing = YES;
  _table.usesAlternatingRowBackgroundColors = YES;
  _table.style = NSTableViewStyleFullWidth;
  _table.rowSizeStyle = NSTableViewRowSizeStyleCustom;
  _table.rowHeight = 22;
  _table.intercellSpacing = NSMakeSize(6, 2);
  _table.target = self;
  _table.doubleAction = @selector(tableDoubleClicked:);
  _table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;

  struct { NSString *ident; uint32_t langID; NSString *title; CGFloat width; BOOL right; } cols[] = {
    { kCol_Name,      kLang_PropName,       @"Name",        300, NO },
    { kCol_Size,      kLang_PropSize,       @"Size",        90,  YES },
    { kCol_Packed,    kLang_PropPackedSize, @"Packed Size", 90,  YES },
    { kCol_MTime,     kLang_PropMTime,      @"Modified",    150, NO },
    { kCol_Kind,      kLang_PropType,       @"Type",        130, NO },
    { kCol_Method,    kLang_PropMethod,     @"Method",      110, NO },
    { kCol_Encrypted, kLang_PropEncrypted,  @"Encrypted",   70,  NO },
    { kCol_CRC,       kLang_PropCRC,        @"CRC",         80,  NO },
    { kCol_Attrib,    kLang_PropAttributes, @"Attributes",  100, NO },
  };
  for (auto &c : cols)
  {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c.ident];
    col.title = SZLang(c.langID, c.title);
    col.width = c.width;
    col.minWidth = 40;
    col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c.ident ascending:YES];
    if (c.right)
      col.headerCell.alignment = NSTextAlignmentRight;
    [_table addTableColumn:col];
  }
  [_table tableColumnWithIdentifier:kCol_Name].resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;

  NSMenu *headerMenu = [[NSMenu alloc] init];
  headerMenu.delegate = self;
  headerMenu.identifier = @"header";
  _table.headerView.menu = headerMenu;

  NSMenu *contextMenu = [[NSMenu alloc] init];
  contextMenu.delegate = self;
  contextMenu.identifier = @"context";
  _table.menu = contextMenu;

  [_table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
  [_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
  [_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];

  NSScrollView *scroll = [[NSScrollView alloc] init];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;

  // address bar
  _pathControl = [[NSPathControl alloc] init];
  _pathControl.pathStyle = NSPathStyleStandard;
  _pathControl.focusRingType = NSFocusRingTypeNone;
  _pathControl.target = self;
  _pathControl.action = @selector(pathControlClicked:);
  _pathControl.translatesAutoresizingMaskIntoConstraints = NO;
  [_pathControl setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  // status bar
  _statusLabel = SZSecondaryLabel(@"");
  _statusLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
  _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _statusRight = SZSecondaryLabel(@"");
  _statusRight.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
  _statusRight.alignment = NSTextAlignmentRight;
  _statusRight.translatesAutoresizingMaskIntoConstraints = NO;

  NSBox *sep1 = SZSeparator();
  NSBox *sep2 = SZSeparator();
  sep1.translatesAutoresizingMaskIntoConstraints = NO;
  sep2.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *pane = [[NSView alloc] init];
  for (NSView *v in @[_pathControl, sep1, scroll, sep2, _statusLabel, _statusRight])
    [pane addSubview:v];
  NSLayoutGuide *safe = pane.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [_pathControl.topAnchor constraintEqualToAnchor:safe.topAnchor constant:5],
    [_pathControl.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor constant:8],
    [_pathControl.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor constant:-8],
    [_pathControl.heightAnchor constraintEqualToConstant:22],
    [sep1.topAnchor constraintEqualToAnchor:_pathControl.bottomAnchor constant:5],
    [sep1.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
    [sep1.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:sep1.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
    [sep2.topAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [sep2.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
    [sep2.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
    [_statusLabel.topAnchor constraintEqualToAnchor:sep2.bottomAnchor constant:4],
    [_statusLabel.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor constant:10],
    [_statusLabel.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor constant:-5],
    [_statusRight.centerYAnchor constraintEqualToAnchor:_statusLabel.centerYAnchor],
    [_statusRight.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor constant:-10],
    [_statusRight.leadingAnchor constraintGreaterThanOrEqualToAnchor:_statusLabel.trailingAnchor constant:12],
  ]];
  NSViewController *listVC = [[NSViewController alloc] init];
  listVC.view = pane;

  _splitVC = [[NSSplitViewController alloc] init];
  NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:sideVC];
  sideItem.minimumThickness = 150;
  sideItem.maximumThickness = 300;
  sideItem.preferredThicknessFraction = 0.18;
  sideItem.canCollapse = YES;
  NSSplitViewItem *listItem = [NSSplitViewItem splitViewItemWithViewController:listVC];
  listItem.minimumThickness = 360;
  [_splitVC addSplitViewItem:sideItem];
  [_splitVC addSplitViewItem:listItem];
  _splitVC.splitView.autosaveName = @"7-Zip Browser Split";
  NSRect frame = self.window.frame;
  self.window.contentViewController = _splitVC;
  [self.window setFrame:frame display:NO];
}

- (void)reloadSidebar
{
  NSMutableArray *items = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  [items addObject:[SZSidebarItem group:SZStripAmp(SZLang(kLang_MenuFavorites, @"Favorites"))]];
  NSString *home = NSHomeDirectory();
  [items addObject:[SZSidebarItem item:[fm displayNameAtPath:home] path:home symbol:@"house"]];
  struct { NSSearchPathDirectory dir; NSString *symbol; } dirs[] = {
    { NSDesktopDirectory, @"menubar.dock.rectangle" },
    { NSDocumentDirectory, @"doc" },
    { NSDownloadsDirectory, @"arrow.down.circle" },
    { NSApplicationDirectory, @"square.grid.3x3" },
  };
  for (auto &d : dirs)
  {
    NSString *p = NSSearchPathForDirectoriesInDomains(d.dir, d.dir == NSApplicationDirectory ? NSLocalDomainMask : NSUserDomainMask, YES).firstObject;
    if (p && [fm fileExistsAtPath:p])
      [items addObject:[SZSidebarItem item:[fm displayNameAtPath:p] path:p symbol:d.symbol]];
  }
  [items addObject:[SZSidebarItem group:SZStripAmp(SZLang(kLang_Computer, @"Computer"))]];
  NSArray<NSURL *> *vols = [fm mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLVolumeLocalizedNameKey, NSURLVolumeIsInternalKey]
      options:NSVolumeEnumerationSkipHiddenVolumes];
  for (NSURL *u in vols)
  {
    NSString *name = nil;
    [u getResourceValue:&name forKey:NSURLVolumeLocalizedNameKey error:nil];
    NSNumber *internal = nil;
    [u getResourceValue:&internal forKey:NSURLVolumeIsInternalKey error:nil];
    [items addObject:[SZSidebarItem item:name ?: u.path.lastPathComponent path:u.path
        symbol:(internal.boolValue ? @"internaldrive" : @"externaldrive")]];
  }
  _sidebarItems = items;
  [_sidebar reloadData];
}

static NSImage *ToolbarImage(NSString *symbol, NSColor *color)
{
  NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
  if (!img)
    return nil;
  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium];
  if (color)
  {
    if (@available(macOS 12.0, *))
      cfg = [cfg configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
  }
  return [img imageWithSymbolConfiguration:cfg];
}

- (void)buildToolbar
{
  NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"7-Zip Browser Toolbar"];
  tb.delegate = self;
  tb.displayMode = NSToolbarDisplayModeIconAndLabel;
  tb.allowsUserCustomization = YES;
  tb.autosavesConfiguration = YES;
  self.window.toolbar = tb;
  if (@available(macOS 11.0, *))
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
  return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
      kTB_Back, kTB_Up, NSToolbarSpaceItemIdentifier,
      kTB_Add, kTB_Extract, kTB_Test, NSToolbarSpaceItemIdentifier,
      kTB_Delete, kTB_Info, NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
  return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
      kTB_Back, kTB_Up, kTB_Add, kTB_Extract, kTB_Test, kTB_Delete, kTB_Info,
      NSToolbarSpaceItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag
{
  if ([ident isEqualToString:kTB_Back])
  {
    _navControl = [NSSegmentedControl segmentedControlWithImages:@[
        SZSymbol(@"chevron.left", 0), SZSymbol(@"chevron.right", 0)]
        trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(navClicked:)];
    _navControl.segmentStyle = NSSegmentStyleSeparated;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.view = _navControl;
    item.label = @"Back/Forward";
    item.paletteLabel = item.label;
    item.navigational = YES;
    [self updateNavigation];
    return item;
  }

  NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
  item.target = self;
  item.bordered = YES;
  if ([ident isEqualToString:kTB_Up])
  {
    item.label = SZStripAmp(SZLang(kLang_OpenParentFolder, @"Up One Level"));
    item.image = ToolbarImage(@"arrow.up", nil);
    item.action = @selector(goUp:);
    item.navigational = YES;
  }
  else if ([ident isEqualToString:kTB_Add])
  {
    item.label = SZStripAmp(SZLang(kLang_Add, @"Add"));
    item.image = ToolbarImage(@"plus", [NSColor systemGreenColor]);
    item.action = @selector(addFiles:);
  }
  else if ([ident isEqualToString:kTB_Extract])
  {
    item.label = SZStripAmp(SZLang(kLang_Extract, @"Extract"));
    item.image = ToolbarImage(@"minus", [NSColor systemBlueColor]);
    item.action = @selector(extractFiles:);
  }
  else if ([ident isEqualToString:kTB_Test])
  {
    item.label = SZStripAmp(SZLang(kLang_Test, @"Test"));
    item.image = ToolbarImage(@"checkmark", [NSColor systemTealColor]);
    item.action = @selector(testFiles:);
  }
  else if ([ident isEqualToString:kTB_Delete])
  {
    item.label = SZStripAmp(SZLang(kLang_ButtonDelete, @"Delete"));
    item.image = ToolbarImage(@"xmark", [NSColor systemRedColor]);
    item.action = @selector(deleteFiles:);
  }
  else if ([ident isEqualToString:kTB_Info])
  {
    item.label = SZStripAmp(SZLang(kLang_ButtonInfo, @"Info"));
    item.image = ToolbarImage(@"info.circle", nil);
    item.action = @selector(showInfo:);
  }
  item.paletteLabel = item.label;
  item.toolTip = item.label;
  return item;
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item
{
  return [self validateAction:item.action];
}

// ---------- state helpers ----------

- (BOOL)inArchive
{
  return _archive != nil;
}

- (NSArray<SZListItem *> *)selectedItems
{
  NSMutableArray *a = [NSMutableArray array];
  [_table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    if (i < self->_items.count)
      [a addObject:self->_items[i]];
  }];
  return a;
}

- (NSArray<SZListItem *> *)clickedOrSelectedItems
{
  const NSInteger clicked = _table.clickedRow;
  if (clicked >= 0 && ![_table isRowSelected:clicked] && (NSUInteger)clicked < _items.count)
    return @[_items[(NSUInteger)clicked]];
  return [self selectedItems];
}

- (NSArray<NSString *> *)selectedPaths
{
  NSMutableArray *a = [NSMutableArray array];
  for (SZListItem *i in [self clickedOrSelectedItems])
    if (i.fsPath)
      [a addObject:i.fsPath];
  return a;
}

- (NSArray<SZArchiveNode *> *)selectedNodes
{
  NSMutableArray *a = [NSMutableArray array];
  for (SZListItem *i in [self clickedOrSelectedItems])
    if (i.node)
      [a addObject:i.node];
  return a;
}

- (SZLocation *)currentLocation
{
  SZLocation *l = [[SZLocation alloc] init];
  l.fsPath = _fsPath;
  l.archive = _archive;
  l.archiveFolder = _node ? [_node pathInArchive] : nil;
  return l;
}

- (void)pushHistory
{
  if (!_fsPath && !_archive)
    return;
  [_back addObject:[self currentLocation]];
  if (_back.count > 50)
    [_back removeObjectAtIndex:0];
  [_forward removeAllObjects];
}

- (void)updateNavigation
{
  [_navControl setEnabled:(_back.count > 0) forSegment:0];
  [_navControl setEnabled:(_forward.count > 0) forSegment:1];
}

// ---------- navigation ----------

- (void)navigateToPath:(NSString *)path
{
  path = [path stringByStandardizingPath];
  BOOL isDir = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir])
  {
    SZShowAlert(self.window, SZLangFormat(kLang_CantOpenArchive, @"Cannot open file '{0}' as archive", path), nil, NSAlertStyleWarning);
    if (!_fsPath && !_archive)
      [self showFolder:NSHomeDirectory() select:nil addHistory:NO];
    return;
  }
  if (isDir)
    [self showFolder:path select:nil addHistory:YES];
  else
  {
    if (!_fsPath && !_archive)
      [self showFolder:[path stringByDeletingLastPathComponent] select:path.lastPathComponent addHistory:NO];
    [self openArchiveFile:path parent:nil pathInParent:nil fallbackOpen:NO];
  }
}

- (void)showFolder:(NSString *)path select:(NSString *)selectName addHistory:(BOOL)addHistory
{
  if (addHistory)
    [self pushHistory];
  _archive = nil;
  _node = nil;
  _fsPath = [path copy];
  [[NSUserDefaults standardUserDefaults] setObject:path forKey:kKey_LastFolder];
  [self reloadItems];
  [self selectName:selectName];
  [self updateTitle];
  [self updateNavigation];
}

- (void)showArchive:(SZArchive *)archive folder:(NSString *)folder select:(NSString *)selectName addHistory:(BOOL)addHistory
{
  if (addHistory)
    [self pushHistory];
  _archive = archive;
  SZArchive *outer = archive;
  while (outer.parentArchive)
    outer = outer.parentArchive;
  _fsPath = [outer.path stringByDeletingLastPathComponent];
  _node = [archive.root nodeAtPath:folder ?: @""] ?: archive.root;
  [self reloadItems];
  [self selectName:selectName];
  [self updateTitle];
  [self updateNavigation];
}

- (void)goToLocation:(SZLocation *)l
{
  if (l.archive)
    [self showArchive:l.archive folder:l.archiveFolder select:nil addHistory:NO];
  else if (l.fsPath)
    [self showFolder:l.fsPath select:nil addHistory:NO];
}

- (void)navClicked:(NSSegmentedControl *)sender
{
  if (sender.selectedSegment == 0)
    [self goBack:sender];
  else
    [self goForward:sender];
}

- (IBAction)goBack:(id)sender
{
  if (_back.count == 0)
    return;
  SZLocation *l = _back.lastObject;
  [_back removeLastObject];
  [_forward addObject:[self currentLocation]];
  [self goToLocation:l];
}

- (IBAction)goForward:(id)sender
{
  if (_forward.count == 0)
    return;
  SZLocation *l = _forward.lastObject;
  [_forward removeLastObject];
  [_back addObject:[self currentLocation]];
  [self goToLocation:l];
}

- (IBAction)goUp:(id)sender
{
  if (_archive)
  {
    if (_node && _node.parent)
    {
      NSString *name = _node.name;
      [self showArchive:_archive folder:[_node.parent pathInArchive] select:name addHistory:YES];
      return;
    }
    if (_archive.parentArchive)
    {
      SZArchive *p = _archive.parentArchive;
      NSString *pip = _archive.pathInParent;
      [self showArchive:p folder:[pip stringByDeletingLastPathComponent] select:pip.lastPathComponent addHistory:YES];
      return;
    }
    [self showFolder:[_archive.path stringByDeletingLastPathComponent] select:_archive.path.lastPathComponent addHistory:YES];
    return;
  }
  if (_fsPath && ![_fsPath isEqualToString:@"/"])
    [self showFolder:[_fsPath stringByDeletingLastPathComponent] select:_fsPath.lastPathComponent addHistory:YES];
}

- (IBAction)goRoot:(id)sender
{
  if (_archive)
    [self showArchive:_archive folder:@"" select:nil addHistory:YES];
  else
    [self showFolder:@"/" select:nil addHistory:YES];
}

- (void)pathControlClicked:(NSPathControl *)sender
{
  NSPathControlItem *clicked = sender.clickedPathItem;
  if (!clicked)
    return;
  const NSUInteger index = [sender.pathItems indexOfObject:clicked];
  if (index == NSNotFound)
    return;
  if (index >= _pathTargets.count)
    return;
  [self goToLocation:_pathTargets[index] addHistory:YES];
}

- (void)goToLocation:(SZLocation *)l addHistory:(BOOL)addHistory
{
  if (addHistory)
    [self pushHistory];
  [self goToLocation:l];
  [self updateNavigation];
}

- (void)updatePathControl
{
  NSMutableArray<NSPathControlItem *> *items = [NSMutableArray array];
  NSMutableArray<SZLocation *> *targets = [NSMutableArray array];

  NSString *fsFolder = _fsPath ?: @"/";
  NSMutableArray<NSString *> *fsChain = [NSMutableArray array];
  NSString *p = fsFolder;
  for (;;)
  {
    [fsChain insertObject:p atIndex:0];
    if ([p isEqualToString:@"/"] || p.length == 0)
      break;
    p = [p stringByDeletingLastPathComponent];
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *f in fsChain)
  {
    NSPathControlItem *it = [[NSPathControlItem alloc] init];
    it.title = [fm displayNameAtPath:f];
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:f];
    icon.size = NSMakeSize(16, 16);
    it.image = icon;
    [items addObject:it];
    SZLocation *l = [[SZLocation alloc] init];
    l.fsPath = f;
    [targets addObject:l];
  }

  if (_archive)
  {
    NSMutableArray<SZArchive *> *chain = [NSMutableArray array];
    for (SZArchive *a = _archive; a; a = a.parentArchive)
      [chain insertObject:a atIndex:0];
    for (NSUInteger k = 0; k < chain.count; k++)
    {
      SZArchive *a = chain[k];
      NSString *innerFolder = (k + 1 < chain.count) ? [chain[k + 1].pathInParent stringByDeletingLastPathComponent] :
          [_node pathInArchive];
      NSPathControlItem *it = [[NSPathControlItem alloc] init];
      it.title = a.displayName;
      it.image = [self iconForName:a.displayName isDir:NO];
      [items addObject:it];
      SZLocation *l = [[SZLocation alloc] init];
      l.archive = a;
      l.archiveFolder = @"";
      [targets addObject:l];
      NSString *acc = @"";
      for (NSString *part in [innerFolder componentsSeparatedByString:@"/"])
      {
        if (part.length == 0)
          continue;
        acc = acc.length ? [acc stringByAppendingFormat:@"/%@", part] : part;
        NSPathControlItem *di = [[NSPathControlItem alloc] init];
        di.title = part;
        di.image = [self iconForName:part isDir:YES];
        [items addObject:di];
        SZLocation *dl = [[SZLocation alloc] init];
        dl.archive = a;
        dl.archiveFolder = acc;
        [targets addObject:dl];
      }
    }
  }
  _pathControl.pathItems = items;
  _pathTargets = targets;
}

- (void)updateTitle
{
  NSString *title;
  if (_archive)
  {
    title = _archive.displayName;
    NSString *inner = [_node pathInArchive];
    if (inner.length)
      title = [NSString stringWithFormat:@"%@ — %@", inner.lastPathComponent, title];
    SZArchive *outer = _archive;
    while (outer.parentArchive)
      outer = outer.parentArchive;
    self.window.representedURL = [NSURL fileURLWithPath:outer.path];
    self.window.subtitle = [NSString stringWithFormat:@"%@%@", _archive.formatName,
        _archive.canUpdate ? @"" : @" · read-only"];
  }
  else
  {
    title = [[NSFileManager defaultManager] displayNameAtPath:_fsPath ?: @"/"];
    self.window.representedURL = [NSURL fileURLWithPath:_fsPath ?: @"/"];
    self.window.subtitle = @"";
  }
  self.window.title = title;
  [self updatePathControl];
  [self updateStatus];
}

// ---------- items ----------

- (NSImage *)iconForName:(NSString *)name isDir:(BOOL)isDir
{
  NSString *ext = isDir ? @"/" : name.pathExtension.lowercaseString;
  NSImage *icon = [_iconCache objectForKey:ext];
  if (icon)
    return icon;
  if (isDir)
    icon = [[NSWorkspace sharedWorkspace] iconForContentType:UTTypeFolder];
  else
  {
    UTType *t = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
    icon = [[NSWorkspace sharedWorkspace] iconForContentType:t ?: UTTypeData];
  }
  icon = [icon copy];
  icon.size = NSMakeSize(16, 16);
  [_iconCache setObject:icon forKey:ext];
  return icon;
}

- (void)reloadItems
{
  NSMutableArray<SZListItem *> *items = [NSMutableArray array];
  if (_archive)
  {
    for (SZArchiveNode *n in _node.children)
    {
      SZListItem *i = [[SZListItem alloc] init];
      i.name = n.name;
      i.isDir = n.isDir;
      i.node = n;
      if (n.sizeDefined)
        i.size = @(n.size);
      if (n.packSizeDefined)
        i.packSize = @(n.packSize);
      i.mtime = n.mtime;
      i.method = n.method;
      i.encrypted = n.encrypted;
      if (n.crcDefined)
        i.crc = [NSString stringWithFormat:@"%08X", n.crc];
      if (n.attribDefined)
        i.attrib = SZFormatAttrib(n.attrib);
      i.icon = [self iconForName:n.name isDir:n.isDir];
      [items addObject:i];
    }
  }
  else if (_fsPath)
  {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLContentModificationDateKey,
        NSURLIsHiddenKey, NSURLLocalizedTypeDescriptionKey, NSURLIsPackageKey, NSURLIsSymbolicLinkKey];
    NSError *err = nil;
    NSArray<NSURL *> *urls = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:_fsPath]
        includingPropertiesForKeys:keys
        options:(_showHidden ? 0 : NSDirectoryEnumerationSkipsHiddenFiles) error:&err];
    if (!urls && err)
      _statusRight.stringValue = err.localizedDescription;
    for (NSURL *u in urls)
    {
      NSDictionary *v = [u resourceValuesForKeys:keys error:nil];
      SZListItem *i = [[SZListItem alloc] init];
      i.name = u.lastPathComponent;
      i.fsPath = u.path;
      i.isDir = [v[NSURLIsDirectoryKey] boolValue];
      if (!i.isDir)
        i.size = v[NSURLFileSizeKey];
      i.mtime = v[NSURLContentModificationDateKey];
      i.kind = v[NSURLLocalizedTypeDescriptionKey];
      const BOOL special = [v[NSURLIsPackageKey] boolValue] || [v[NSURLIsSymbolicLinkKey] boolValue];
      if (special)
      {
        NSImage *icon = [[[NSWorkspace sharedWorkspace] iconForFile:u.path] copy];
        icon.size = NSMakeSize(16, 16);
        i.icon = icon;
      }
      else
        i.icon = [self iconForName:i.name isDir:i.isDir];
      [items addObject:i];
    }
  }
  // columns are changed while the table still shows old items
  [self updateColumnsVisibility];
  _items = [self sortedItems:items];
  [_table reloadData];
  [_table deselectAll:nil];
  [_table scrollRowToVisible:0];
  [self updateStatus];
}

- (NSArray<SZListItem *> *)sortedItems:(NSArray<SZListItem *> *)items
{
  NSString *key = _sortKey;
  const BOOL asc = _sortAscending;
  return [items sortedArrayUsingComparator:^NSComparisonResult(SZListItem *a, SZListItem *b) {
    if (a.isDir != b.isDir)
      return a.isDir ? NSOrderedAscending : NSOrderedDescending;
    NSComparisonResult r = NSOrderedSame;
    if ([key isEqualToString:kCol_Size])
      r = [(a.size ?: @0) compare:(b.size ?: @0)];
    else if ([key isEqualToString:kCol_Packed])
      r = [(a.packSize ?: @0) compare:(b.packSize ?: @0)];
    else if ([key isEqualToString:kCol_MTime])
      r = [(a.mtime ?: [NSDate distantPast]) compare:(b.mtime ?: [NSDate distantPast])];
    else if ([key isEqualToString:kCol_Kind])
      r = [(a.kind ?: a.name.pathExtension) localizedStandardCompare:(b.kind ?: b.name.pathExtension)];
    else if ([key isEqualToString:kCol_Method])
      r = [(a.method ?: @"") compare:(b.method ?: @"")];
    else if ([key isEqualToString:kCol_CRC])
      r = [(a.crc ?: @"") compare:(b.crc ?: @"")];
    else if ([key isEqualToString:kCol_Attrib])
      r = [(a.attrib ?: @"") compare:(b.attrib ?: @"")];
    else if ([key isEqualToString:kCol_Encrypted])
      r = [@(a.encrypted) compare:@(b.encrypted)];
    if (r == NSOrderedSame)
      r = [a.name localizedStandardCompare:b.name];
    if (!asc)
      r = (NSComparisonResult)(-r);
    return r;
  }];
}

- (NSSet<NSString *> *)hiddenColumns
{
  NSArray *a = [[NSUserDefaults standardUserDefaults] stringArrayForKey:kKey_HiddenColumns];
  return [NSSet setWithArray:a ?: @[kCol_Attrib]];
}

- (void)updateColumnsVisibility
{
  NSSet *hidden = [self hiddenColumns];
  const BOOL arc = [self inArchive];
  for (NSTableColumn *c in _table.tableColumns)
  {
    NSString *ident = c.identifier;
    BOOL show;
    if ([ident isEqualToString:kCol_Name])
      show = YES;
    else if ([ident isEqualToString:kCol_Kind])
      show = !arc;
    else if ([@[kCol_Packed, kCol_Method, kCol_Encrypted, kCol_CRC, kCol_Attrib] containsObject:ident])
      show = arc;
    else
      show = YES;
    if ([hidden containsObject:ident])
      show = NO;
    c.hidden = !show;
  }
  [self fitNameColumn];
}

// the Name column gets all free space, other columns keep their widths
- (void)fitNameColumn
{
  NSTableColumn *name = [_table tableColumnWithIdentifier:kCol_Name];
  const CGFloat spacing = _table.intercellSpacing.width;
  CGFloat others = 0;
  for (NSTableColumn *c in _table.tableColumns)
    if (c != name && !c.hidden)
      others += c.width + spacing;
  const CGFloat avail = _table.enclosingScrollView.contentView.bounds.size.width;
  if (avail <= 0)
    return;
  CGFloat w = avail - others - spacing - 4;
  if (w < 180)
    w = 180;
  name.width = w;
}

- (void)selectName:(NSString *)name
{
  if (!name)
    return;
  for (NSUInteger i = 0; i < _items.count; i++)
    if ([_items[i].name isEqualToString:name])
    {
      [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
      [_table scrollRowToVisible:(NSInteger)i];
      return;
    }
}

- (void)selectNames:(NSSet<NSString *> *)names
{
  NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
  for (NSUInteger i = 0; i < _items.count; i++)
    if ([names containsObject:_items[i].name])
      [set addIndex:i];
  [_table selectRowIndexes:set byExtendingSelection:NO];
}

- (void)updateStatus
{
  NSArray<SZListItem *> *sel = [self selectedItems];
  uint64_t size = 0;
  for (SZListItem *i in sel)
    size += i.size.unsignedLongLongValue;
  NSString *left;
  if (sel.count)
  {
    left = SZLangFormat(kLang_NSelectedItems, @"{0} object(s) selected", [NSString stringWithFormat:@"%lu", (unsigned long)sel.count]);
    if (size)
      left = [left stringByAppendingFormat:@" — %@", SZFormatSize(size)];
  }
  else
    left = [NSString stringWithFormat:@"%lu %@", (unsigned long)_items.count, _items.count == 1 ? @"item" : @"items"];
  _statusLabel.stringValue = left;

  if (_archive)
  {
    SZArchiveNode *r = _archive.root;
    _statusRight.stringValue = [NSString stringWithFormat:@"%@ · %llu %@ · %llu %@ · %@",
        _archive.formatName, r.numFiles, SZStripAmp(SZLang(kLang_PropFiles, @"Files")),
        r.numFolders, SZStripAmp(SZLang(kLang_PropFolders, @"Folders")), SZFormatSize(r.size)];
  }
  else
    _statusRight.stringValue = @"";
}

// ---------- table data source ----------

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  if (tableView == _sidebar)
    return (NSInteger)_sidebarItems.count;
  return (NSInteger)_items.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
  return tableView == _sidebar && _sidebarItems[(NSUInteger)row].isGroup;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
  if (tableView == _sidebar)
    return !_sidebarItems[(NSUInteger)row].isGroup;
  return YES;
}

static NSTextField *CellText(NSTableView *tv, NSString *ident, id owner, BOOL right)
{
  NSTextField *t = [tv makeViewWithIdentifier:ident owner:owner];
  if (!t)
  {
    t = [NSTextField labelWithString:@""];
    t.identifier = ident;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    t.alignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    if (right)
      t.font = [NSFont monospacedDigitSystemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightRegular];
  }
  return t;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
  if (tableView == _sidebar)
  {
    SZSidebarItem *si = _sidebarItems[(NSUInteger)row];
    if (si.isGroup)
    {
      NSTableCellView *v = [tableView makeViewWithIdentifier:@"group" owner:self];
      if (!v)
      {
        v = [[NSTableCellView alloc] init];
        v.identifier = @"group";
        NSTextField *t = SZSecondaryLabel(@"");
        t.font = [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]];
        t.translatesAutoresizingMaskIntoConstraints = NO;
        [v addSubview:t];
        v.textField = t;
        [NSLayoutConstraint activateConstraints:@[
          [t.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
          [t.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        ]];
      }
      v.textField.stringValue = si.title;
      return v;
    }
    NSTableCellView *v = [tableView makeViewWithIdentifier:@"side" owner:self];
    if (!v)
    {
      v = [[NSTableCellView alloc] init];
      v.identifier = @"side";
      NSImageView *iv = [[NSImageView alloc] init];
      iv.translatesAutoresizingMaskIntoConstraints = NO;
      iv.contentTintColor = [NSColor controlAccentColor];
      NSTextField *t = SZLabel(@"");
      t.translatesAutoresizingMaskIntoConstraints = NO;
      [v addSubview:iv];
      [v addSubview:t];
      v.imageView = iv;
      v.textField = t;
      [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4],
        [iv.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:18],
        [t.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
        [t.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-4],
        [t.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
      ]];
    }
    v.imageView.image = si.icon;
    v.textField.stringValue = si.title;
    return v;
  }

  SZListItem *it = _items[(NSUInteger)row];
  NSString *ident = col.identifier;
  if ([ident isEqualToString:kCol_Name])
  {
    NSTableCellView *v = [tableView makeViewWithIdentifier:@"nameCell" owner:self];
    if (!v)
    {
      v = [[NSTableCellView alloc] init];
      v.identifier = @"nameCell";
      NSImageView *iv = [[NSImageView alloc] init];
      iv.translatesAutoresizingMaskIntoConstraints = NO;
      NSTextField *t = SZLabel(@"");
      t.lineBreakMode = NSLineBreakByTruncatingMiddle;
      t.translatesAutoresizingMaskIntoConstraints = NO;
      [v addSubview:iv];
      [v addSubview:t];
      v.imageView = iv;
      v.textField = t;
      [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
        [iv.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:16],
        [iv.heightAnchor constraintEqualToConstant:16],
        [t.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
        [t.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-2],
        [t.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
      ]];
    }
    v.imageView.image = it.icon;
    v.textField.stringValue = it.name;
    return v;
  }

  const BOOL right = [ident isEqualToString:kCol_Size] || [ident isEqualToString:kCol_Packed];
  NSTextField *t = CellText(tableView, ident, self, right);
  NSString *s = @"";
  if ([ident isEqualToString:kCol_Size])
  {
    if (it.size && !(it.isDir && !_archive))
      s = SZFormatSize(it.size.unsignedLongLongValue);
    t.toolTip = it.size ? [NSString stringWithFormat:@"%@ bytes", SZFormatSizeExact(it.size.unsignedLongLongValue)] : nil;
  }
  else if ([ident isEqualToString:kCol_Packed])
    s = it.packSize ? SZFormatSize(it.packSize.unsignedLongLongValue) : @"";
  else if ([ident isEqualToString:kCol_MTime])
    s = it.mtime ? SZFormatDate(it.mtime) : @"";
  else if ([ident isEqualToString:kCol_Kind])
    s = it.kind ?: @"";
  else if ([ident isEqualToString:kCol_Method])
    s = it.method ?: @"";
  else if ([ident isEqualToString:kCol_Encrypted])
    s = it.encrypted ? @"+" : @"";
  else if ([ident isEqualToString:kCol_CRC])
    s = it.crc ?: @"";
  else if ([ident isEqualToString:kCol_Attrib])
    s = it.attrib ?: @"";
  t.stringValue = s;
  t.textColor = [ident isEqualToString:kCol_Name] ? [NSColor labelColor] : [NSColor secondaryLabelColor];
  return t;
}

- (NSString *)tableView:(NSTableView *)tableView typeSelectStringForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
  if (tableView == _table && [col.identifier isEqualToString:kCol_Name])
    return _items[(NSUInteger)row].name;
  return nil;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors
{
  NSSortDescriptor *d = tableView.sortDescriptors.firstObject;
  if (!d)
    return;
  NSSet *selected = [NSSet setWithArray:[[self selectedItems] valueForKey:@"name"]];
  _sortKey = d.key;
  _sortAscending = d.ascending;
  _items = [self sortedItems:_items];
  [_table reloadData];
  [self selectNames:selected];
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
  if (n.object == _sidebar)
  {
    const NSInteger row = _sidebar.selectedRow;
    if (row >= 0)
    {
      SZSidebarItem *si = _sidebarItems[(NSUInteger)row];
      if (si.path)
        [self showFolder:si.path select:nil addHistory:YES];
    }
    return;
  }
  [self updateStatus];
}

// ---------- drag and drop ----------

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row
{
  if (tableView != _table)
    return nil;
  SZListItem *it = _items[(NSUInteger)row];
  if (it.fsPath)
    return [NSURL fileURLWithPath:it.fsPath];
  if (it.node)
  {
    NSString *type = it.isDir ? UTTypeFolder.identifier :
        ([UTType typeWithFilenameExtension:it.name.pathExtension] ?: UTTypeData).identifier;
    NSFilePromiseProvider *p = [[NSFilePromiseProvider alloc] initWithFileType:type delegate:self];
    p.userInfo = it.node;
    return p;
  }
  return nil;
}

- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)provider fileNameForType:(NSString *)fileType
{
  return ((SZArchiveNode *)provider.userInfo).name;
}

- (NSOperationQueue *)operationQueueForFilePromiseProvider:(NSFilePromiseProvider *)provider
{
  return _promiseQueue;
}

- (void)filePromiseProvider:(NSFilePromiseProvider *)provider writePromiseToURL:(NSURL *)url
    completionHandler:(void (^)(NSError *))completionHandler
{
  // it's called in _promiseQueue thread.
  // We extract the item to temp folder and then move it to destination.
  SZArchiveNode *node = provider.userInfo;
  SZArchive *archive = _archive;
  NSString *tmp = SZCreateTempSubfolder();
  __block BOOL ok = NO;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    [self extractNodes:@[node] archive:archive toDir:tmp pathMode:kPathMode_Full
        overwrite:kOverwriteMode_Overwrite password:nil test:NO completion:^(BOOL success) {
      ok = success;
      dispatch_semaphore_signal(sem);
    }];
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  NSError *err = nil;
  NSString *src = [tmp stringByAppendingPathComponent:node.name];
  if ([[NSFileManager defaultManager] fileExistsAtPath:src])
    [[NSFileManager defaultManager] moveItemAtURL:[NSURL fileURLWithPath:src] toURL:url error:&err];
  else if (!ok)
    err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
  [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
  completionHandler(err);
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info
    proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op
{
  if (tableView != _table || info.draggingSource == _table)
    return NSDragOperationNone;
  [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
  if (_archive)
    return _archive.canUpdate ? NSDragOperationCopy : NSDragOperationNone;
  return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op
{
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  if (urls.count == 0)
    return NO;
  NSArray *paths = [urls valueForKey:@"path"];
  if (_archive)
    [self addPaths:paths toArchiveFolder:[_node pathInArchive]];
  else
  {
    // dropping files to folder: offer to compress them, like "Add to archive"
    if (paths.count == 1 && SZIsArchivePath(paths[0]))
      [self openArchiveFile:paths[0] parent:nil pathInParent:nil fallbackOpen:NO];
    else
      SZCompressFiles(paths, self.window, ^(BOOL ok) { [self refresh:nil]; });
  }
  return YES;
}

// ---------- archive operations ----------

- (void)openArchiveFile:(NSString *)path parent:(SZArchive *)parent pathInParent:(NSString *)pathInParent fallbackOpen:(BOOL)fallbackOpen
{
  [self openArchiveFile:path password:nil parent:parent pathInParent:pathInParent fallbackOpen:fallbackOpen
      folder:nil select:nil addHistory:YES];
}

- (void)openArchiveFile:(NSString *)path password:(NSString *)password parent:(SZArchive *)parent pathInParent:(NSString *)pathInParent
    fallbackOpen:(BOOL)fallbackOpen folder:(NSString *)folder select:(NSSet<NSString *> *)select addHistory:(BOOL)addHistory
{
  SZOperation *op = [[SZOperation alloc] initWithTitle:SZLang(kLang_Opening, @"Opening...")];
  op.subtitle = (pathInParent ?: path).lastPathComponent;
  op.quiet = YES; // errors are shown below
  __block SZArchive *result = nil;
  NSString *pw = [password copy];
  _busy = YES;
  [SZProgressController runOperation:op parent:self.window work:^(SZOperation *o) {
    CResult r;
    IArchive *a = OpenArchive(path.fileSystemRepresentation, pw.UTF8String, o.callback, r);
    o.result = r;
    if (a)
      result = [[SZArchive alloc] initWithEngineArchive:a path:path];
  } completion:^(SZOperation *o) {
    self->_busy = NO;
    if (!result)
    {
      const CResult r = o.result;
      if (o.cancelled || r.HResult == (int32_t)0x80004004)
        return;
      // the file is not archive: we open it with default application, like Windows version does
      if (fallbackOpen && r.HResult == 1 /* S_FALSE */ && !r.PasswordWasDefined)
      {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
        return;
      }
      NSString *info = [[o messages] componentsJoinedByString:@"\n\n"];
      if (info.length == 0)
        info = SZResultMessage(r);
      SZShowAlert(self.window, SZLangFormat(kLang_CantOpenArchive, @"Cannot open file '{0}' as archive",
          (pathInParent ?: path).lastPathComponent), info, NSAlertStyleWarning);
      return;
    }
    if (parent)
    {
      result.parentArchive = parent;
      result.pathInParent = pathInParent;
    }
    if (pathInParent)
      result.displayName = pathInParent.lastPathComponent;
    [self showArchive:result folder:folder select:nil addHistory:addHistory];
    if (select)
      [self selectNames:select];
    [self noteRecentDocument:parent ? nil : path];
  }];
}

- (void)noteRecentDocument:(NSString *)path
{
  if (path)
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:path]];
}

// reopens current archive after update and shows same folder
- (void)reopenArchiveSelecting:(NSSet<NSString *> *)select
{
  SZArchive *a = _archive;
  if (!a)
    return;
  NSString *folder = [_node pathInArchive];
  NSString *pw = SZString(a.engineArchive->GetPassword());
  [self openArchiveFile:a.path password:(pw.length ? pw : nil) parent:a.parentArchive pathInParent:a.pathInParent
      fallbackOpen:NO folder:folder select:select addHistory:NO];
}

- (void)extractNodes:(NSArray<SZArchiveNode *> *)nodes archive:(SZArchive *)archive toDir:(NSString *)dir
    pathMode:(EPathMode)pathMode overwrite:(EOverwriteMode)overwrite password:(NSString *)password
    test:(BOOL)test completion:(void (^)(BOOL ok))completion
{
  NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
  for (SZArchiveNode *n in nodes)
    [n collectItemIndices:set];
  std::vector<uint32_t> indices;
  for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i])
    indices.push_back((uint32_t)i);
  // prefix of parent folder of the nodes that will be removed from paths
  NSString *prefix = nodes.count ? [nodes[0].parent folderPrefix] : @"";

  SZOperation *op = [[SZOperation alloc] initWithTitle:test ?
      SZLang(kLang_Testing, @"Testing") : SZLang(kLang_Extracting, @"Extracting")];
  op.subtitle = archive.displayName;
  NSString *dirCopy = [dir copy];
  NSString *pw = [password copy];
  _busy = YES;
  [SZProgressController runOperation:op parent:self.window work:^(SZOperation *o) {
    // archive handlers don't support simultaneous calls
    @synchronized (archive) {
      IArchive *a = archive.engineArchive;
      if (pw.length)
        a->SetPassword(pw.UTF8String);
      CResult r;
      a->Extract(indices.data(), (unsigned)indices.size(), dirCopy.fileSystemRepresentation,
          prefix.UTF8String, pathMode, overwrite, test, o.callback, r);
      o.result = r;
    }
  } completion:^(SZOperation *o) {
    self->_busy = NO;
    const CResult r = o.result;
    const BOOL ok = (r.HResult == 0 && ![o hasErrors] && !o.cancelled);
    if (test)
      SZShowTestResult(o, self.window);
    if (completion)
      completion(ok);
  }];
}

- (NSArray<SZArchiveNode *> *)nodesForOperation
{
  NSArray<SZArchiveNode *> *nodes = [self selectedNodes];
  if (nodes.count == 0 && _node)
    nodes = [_node.children copy];
  return nodes;
}

- (void)addPaths:(NSArray<NSString *> *)paths toArchiveFolder:(NSString *)folder
{
  SZArchive *a = _archive;
  if (!a || !a.canUpdate || paths.count == 0)
  {
    NSBeep();
    return;
  }
  NSArray<NSString *> *sources = paths;
  NSString *staging = nil;
  if (folder.length)
  {
    // 7-Zip can add files only to root folder of archive.
    // So we create the folder structure in temp folder and we clone the files there.
    // (APFS clones files without copying of data)
    staging = SZCreateTempSubfolder();
    NSString *dest = [staging stringByAppendingPathComponent:folder];
    [[NSFileManager defaultManager] createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *p in paths)
    {
      NSError *err = nil;
      if (![[NSFileManager defaultManager] copyItemAtPath:p toPath:[dest stringByAppendingPathComponent:p.lastPathComponent] error:&err])
      {
        SZShowAlert(self.window, err.localizedDescription, p, NSAlertStyleWarning);
        [[NSFileManager defaultManager] removeItemAtPath:staging error:nil];
        return;
      }
    }
    sources = @[[staging stringByAppendingPathComponent:[folder componentsSeparatedByString:@"/"].firstObject]];
  }
  NSMutableArray *args = [NSMutableArray arrayWithObjects:@"a", @"-spd", @"-snl", nil];
  NSString *pw = SZString(a.engineArchive->GetPassword());
  if (pw.length)
    [args addObject:[@"-p" stringByAppendingString:pw]];
  [args addObject:@"--"];
  [args addObject:a.path];
  [args addObjectsFromArray:sources];
  NSSet *names = [NSSet setWithArray:[paths valueForKey:@"lastPathComponent"]];
  SZRunCommand(args, SZLang(kLang_Compressing, @"Compressing"), a.displayName, self.window, ^(BOOL ok) {
    if (staging)
      [[NSFileManager defaultManager] removeItemAtPath:staging error:nil];
    [self reopenArchiveSelecting:names];
  });
}

// ---------- actions ----------

- (BOOL)validateAction:(SEL)action
{
  if (_busy)
    return NO;
  const BOOL arc = [self inArchive];
  const NSUInteger numSel = [self clickedOrSelectedItems].count;
  if (action == @selector(goUp:))
    return arc || (_fsPath && ![_fsPath isEqualToString:@"/"]);
  if (action == @selector(goBack:))
    return _back.count > 0;
  if (action == @selector(goForward:))
    return _forward.count > 0;
  if (action == @selector(addFiles:))
    return arc ? _archive.canUpdate : numSel > 0;
  if (action == @selector(extractFiles:) || action == @selector(testFiles:))
  {
    if (arc)
      return YES;
    for (SZListItem *i in [self clickedOrSelectedItems])
      if (!i.isDir)
        return YES;
    return NO;
  }
  if (action == @selector(deleteFiles:))
    return numSel > 0 && (!arc || _archive.canUpdate);
  if (action == @selector(renameItem:))
    return numSel == 1 && (!arc || _archive.canUpdate);
  if (action == @selector(createFolder:))
    return !arc;
  if (action == @selector(openSelected:) || action == @selector(openOutside:))
    return numSel > 0;
  if (action == @selector(openInside:))
  {
    if (numSel != 1)
      return NO;
    return ![self clickedOrSelectedItems].firstObject.isDir;
  }
  if (action == @selector(showInFinder:))
    return !arc || numSel == 0;
  if (action == @selector(copyPath:))
    return numSel > 0;
  return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
  if (item.action == @selector(toggleHidden:))
  {
    item.state = _showHidden ? NSControlStateValueOn : NSControlStateValueOff;
    return ![self inArchive];
  }
  return [self validateAction:item.action];
}

- (void)tableDoubleClicked:(id)sender
{
  if (_table.clickedRow < 0)
    return;
  [self openSelected:sender];
}

- (IBAction)openSelected:(id)sender
{
  NSArray<SZListItem *> *sel = [self clickedOrSelectedItems];
  if (sel.count == 0)
    return;
  if (sel.count > 1)
  {
    for (SZListItem *i in sel)
      if (!i.isDir)
        [self openItemOutside:i];
    return;
  }
  SZListItem *it = sel[0];
  if (it.isDir)
  {
    if (it.node)
      [self showArchive:_archive folder:[it.node pathInArchive] select:nil addHistory:YES];
    else
      [self showFolder:it.fsPath select:nil addHistory:YES];
    return;
  }
  if (SZIsArchivePath(it.name))
  {
    [self openItemInside:it fallbackOpen:YES];
    return;
  }
  [self openItemOutside:it];
}

- (IBAction)openInside:(id)sender
{
  SZListItem *it = [self clickedOrSelectedItems].firstObject;
  if (it && !it.isDir)
    [self openItemInside:it fallbackOpen:NO];
}

- (IBAction)openOutside:(id)sender
{
  for (SZListItem *i in [self clickedOrSelectedItems])
    [self openItemOutside:i];
}

- (void)openItemInside:(SZListItem *)it fallbackOpen:(BOOL)fallbackOpen
{
  if (it.fsPath)
  {
    [self openArchiveFile:it.fsPath parent:nil pathInParent:nil fallbackOpen:fallbackOpen];
    return;
  }
  // archive inside archive: we extract it to temp folder
  SZArchive *parent = _archive;
  NSString *tmp = SZCreateTempSubfolder();
  SZArchiveNode *node = it.node;
  [self extractNodes:@[node] archive:parent toDir:tmp pathMode:kPathMode_Full overwrite:kOverwriteMode_Overwrite
      password:nil test:NO completion:^(BOOL ok) {
    NSString *file = [tmp stringByAppendingPathComponent:node.name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:file])
      return;
    [self openArchiveFile:file password:nil parent:parent pathInParent:[node pathInArchive]
        fallbackOpen:NO folder:nil select:nil addHistory:YES];
  }];
}

- (void)openItemOutside:(SZListItem *)it
{
  if (it.fsPath)
  {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:it.fsPath]];
    return;
  }
  // file in archive: extract to temp folder and open with default application
  NSString *tmp = SZCreateTempSubfolder();
  SZArchiveNode *node = it.node;
  [self extractNodes:@[node] archive:_archive toDir:tmp pathMode:kPathMode_Full overwrite:kOverwriteMode_Overwrite
      password:nil test:NO completion:^(BOOL ok) {
    NSString *file = [tmp stringByAppendingPathComponent:node.name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:file])
      [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:file]];
  }];
}

- (IBAction)addFiles:(id)sender
{
  if ([self inArchive])
  {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = YES;
    p.allowsMultipleSelection = YES;
    p.prompt = SZStripAmp(SZLang(kLang_Add, @"Add"));
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
      if (r == NSModalResponseOK)
        [self addPaths:[p.URLs valueForKey:@"path"] toArchiveFolder:[self->_node pathInArchive]];
    }];
    return;
  }
  NSArray *paths = [self selectedPaths];
  if (paths.count == 0)
  {
    NSBeep();
    return;
  }
  NSSet *names = [NSSet setWithArray:[paths valueForKey:@"lastPathComponent"]];
  SZCompressFiles(paths, self.window, ^(BOOL ok) {
    [self reloadItems];
    [self selectNames:names];
  });
}

- (IBAction)extractFiles:(id)sender
{
  if ([self inArchive])
  {
    NSArray<SZArchiveNode *> *nodes = [self nodesForOperation];
    if (nodes.count == 0)
      return;
    SZArchive *outer = _archive;
    while (outer.parentArchive)
      outer = outer.parentArchive;
    NSString *dir = [outer.path stringByDeletingLastPathComponent];
    NSString *sub = nil;
    if ([self selectedNodes].count == 0 && _node == _archive.root)
    {
      sub = [_archive.displayName stringByDeletingPathExtension];
      if ([sub.pathExtension.lowercaseString isEqualToString:@"tar"])
        sub = [sub stringByDeletingPathExtension];
    }
    SZArchive *archive = _archive;
    [SZExtractController showWithDirectory:dir subfolder:sub showElimDup:NO parent:self.window completion:^(SZExtractOptions *o) {
      if (!o)
        return;
      [self extractNodes:nodes archive:archive toDir:o.outputDir pathMode:o.pathMode overwrite:o.overwriteMode
          password:o.password test:NO completion:nil];
    }];
    return;
  }
  NSMutableArray *archives = [NSMutableArray array];
  for (SZListItem *i in [self clickedOrSelectedItems])
    if (!i.isDir && i.fsPath)
      [archives addObject:i.fsPath];
  if (archives.count == 0)
  {
    SZShowAlert(self.window, SZLang(kLang_SelectFiles, @"You must select one or more files"), nil, NSAlertStyleInformational);
    return;
  }
  SZExtractArchives(archives, SZExtractModeDialog, self.window, ^(BOOL ok) { [self refresh:nil]; });
}

- (IBAction)extractHere:(id)sender
{
  NSArray *paths = [self selectedPaths];
  if (paths.count)
    SZExtractArchives(paths, SZExtractModeHere, self.window, ^(BOOL ok) { [self refresh:nil]; });
}

- (IBAction)extractToFolder:(id)sender
{
  NSArray *paths = [self selectedPaths];
  if (paths.count)
    SZExtractArchives(paths, SZExtractModeToFolder, self.window, ^(BOOL ok) { [self refresh:nil]; });
}

- (IBAction)compressTo7z:(id)sender
{
  NSArray *paths = [self selectedPaths];
  if (paths.count)
    SZCompressFilesQuick(paths, @"7z", self.window, ^(BOOL ok) { [self refresh:nil]; });
}

- (IBAction)compressToZip:(id)sender
{
  NSArray *paths = [self selectedPaths];
  if (paths.count)
    SZCompressFilesQuick(paths, @"zip", self.window, ^(BOOL ok) { [self refresh:nil]; });
}

- (IBAction)testFiles:(id)sender
{
  if ([self inArchive])
  {
    NSArray<SZArchiveNode *> *nodes = [self selectedNodes];
    if (nodes.count == 0)
      nodes = [_archive.root.children copy];
    [self extractNodes:nodes archive:_archive toDir:@"" pathMode:kPathMode_Full overwrite:kOverwriteMode_Overwrite
        password:nil test:YES completion:nil];
    return;
  }
  NSMutableArray *archives = [NSMutableArray array];
  for (SZListItem *i in [self clickedOrSelectedItems])
    if (!i.isDir && i.fsPath)
      [archives addObject:i.fsPath];
  SZTestArchives(archives, self.window, nil);
}

- (IBAction)deleteFiles:(id)sender
{
  NSArray<SZListItem *> *sel = [self clickedOrSelectedItems];
  if (sel.count == 0)
    return;
  NSString *title, *msg;
  if (sel.count == 1)
  {
    title = sel[0].isDir ? SZLang(kLang_ConfirmFolderDelete, @"Confirm Folder Delete") : SZLang(kLang_ConfirmFileDelete, @"Confirm File Delete");
    msg = sel[0].isDir ?
        SZLangFormat(kLang_WantDeleteFolder, @"Are you sure you want to delete the folder '{0}' and all its contents?", sel[0].name) :
        SZLangFormat(kLang_WantDeleteFile, @"Are you sure you want to delete '{0}'?", sel[0].name);
  }
  else
  {
    title = SZLang(kLang_ConfirmItemsDelete, @"Confirm Multiple File Delete");
    msg = SZLangFormat(kLang_WantDeleteItems, @"Are you sure you want to delete these {0} items?",
        [NSString stringWithFormat:@"%lu", (unsigned long)sel.count]);
  }
  if (![self inArchive])
    msg = [msg stringByAppendingString:@"\n\n(The items will be moved to the Trash.)"];

  SZConfirm(self.window, title, msg, SZStripAmp(SZLang(kLang_ButtonDelete, @"Delete")), YES, ^(BOOL ok) {
    if (!ok)
      return;
    if ([self inArchive])
    {
      SZArchive *a = self->_archive;
      NSMutableArray *args = [NSMutableArray arrayWithObjects:@"d", @"-spd", nil];
      NSString *pw = SZString(a.engineArchive->GetPassword());
      if (pw.length)
        [args addObject:[@"-p" stringByAppendingString:pw]];
      [args addObject:@"--"];
      [args addObject:a.path];
      for (SZListItem *i in sel)
        [args addObject:[i.node pathInArchive]];
      SZRunCommand(args, SZLang(kLang_Deleting, @"Deleting"), a.displayName, self.window, ^(BOOL done) {
        [self reopenArchiveSelecting:nil];
      });
      return;
    }
    NSMutableArray *urls = [NSMutableArray array];
    for (SZListItem *i in sel)
      [urls addObject:[NSURL fileURLWithPath:i.fsPath]];
    [[NSWorkspace sharedWorkspace] recycleURLs:urls completionHandler:^(NSDictionary *newURLs, NSError *error) {
      if (error)
        SZShowAlert(self.window, error.localizedDescription, nil, NSAlertStyleWarning);
      [self refresh:nil];
    }];
  });
}

- (IBAction)renameItem:(id)sender
{
  SZListItem *it = [self clickedOrSelectedItems].firstObject;
  if (!it)
    return;
  SZAskText(self.window, SZStripAmp(SZLang(kLang_Rename, @"Rename")), it.name, it.name, ^(NSString *text) {
    if (text.length == 0 || [text isEqualToString:it.name] || [text containsString:@"/"])
      return;
    if ([self inArchive])
    {
      SZArchive *a = self->_archive;
      NSString *oldPath = [it.node pathInArchive];
      NSString *newPath = [[oldPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:text];
      NSMutableArray *args = [NSMutableArray arrayWithObjects:@"rn", @"-spd", nil];
      NSString *pw = SZString(a.engineArchive->GetPassword());
      if (pw.length)
        [args addObject:[@"-p" stringByAppendingString:pw]];
      [args addObjectsFromArray:@[@"--", a.path, oldPath, newPath]];
      SZRunCommand(args, SZLang(kLang_OpUpdate, @"Updating"), a.displayName, self.window, ^(BOOL ok) {
        [self reopenArchiveSelecting:[NSSet setWithObject:text]];
      });
      return;
    }
    NSString *dest = [[it.fsPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:text];
    NSError *err = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:it.fsPath toPath:dest error:&err])
      SZShowAlert(self.window, err.localizedDescription, nil, NSAlertStyleWarning);
    [self reloadItems];
    [self selectName:text];
  });
}

- (IBAction)createFolder:(id)sender
{
  if ([self inArchive] || !_fsPath)
    return;
  SZAskText(self.window, SZStripAmp(SZLang(kLang_CreateFolderTitle, @"Create Folder")),
      SZStripAmp(SZLang(kLang_CreateFolderName, @"Folder name:")),
      SZStripAmp(SZLang(kLang_CreateFolderDefault, @"New Folder")), ^(NSString *text) {
    if (text.length == 0)
      return;
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[self->_fsPath stringByAppendingPathComponent:text]
        withIntermediateDirectories:NO attributes:nil error:&err])
      SZShowAlert(self.window, err.localizedDescription, nil, NSAlertStyleWarning);
    [self reloadItems];
    [self selectName:text];
  });
}

- (IBAction)showInfo:(id)sender
{
  NSArray<SZListItem *> *sel = [self clickedOrSelectedItems];
  if ([self inArchive])
  {
    if (sel.count == 1 && sel[0].node.itemIndex >= 0)
    {
      const CPropPair *props = NULL;
      const unsigned n = _archive.engineArchive->GetItemProps((unsigned)sel[0].node.itemIndex, &props);
      NSMutableArray *pairs = [NSMutableArray array];
      for (unsigned i = 0; i < n; i++)
        [pairs addObject:@[SZString(props[i].Name), SZString(props[i].Value)]];
      [SZPropertiesController showProperties:pairs title:sel[0].name icon:[self iconForName:sel[0].name isDir:sel[0].isDir]];
      return;
    }
    if (sel.count == 1 && sel[0].isDir)
    {
      SZArchiveNode *n = sel[0].node;
      NSArray *pairs = @[
        @[SZLang(kLang_PropName, @"Name"), n.name],
        @[SZLang(kLang_PropSize, @"Size"), [NSString stringWithFormat:@"%@ (%@ bytes)", SZFormatSize(n.size), SZFormatSizeExact(n.size)]],
        @[SZLang(kLang_PropPackedSize, @"Packed Size"), SZFormatSizeExact(n.packSize)],
        @[SZLang(kLang_PropFiles, @"Files"), [NSString stringWithFormat:@"%llu", n.numFiles]],
        @[SZLang(kLang_PropFolders, @"Folders"), [NSString stringWithFormat:@"%llu", n.numFolders]],
      ];
      [SZPropertiesController showProperties:pairs title:n.name icon:[self iconForName:n.name isDir:YES]];
      return;
    }
    IArchive *a = _archive.engineArchive;
    NSMutableArray *pairs = [NSMutableArray array];
    for (unsigned i = 0; i < a->GetNumProps(); i++)
    {
      const CPropPair p = a->GetProp(i);
      [pairs addObject:@[SZString(p.Name), SZString(p.Value)]];
    }
    SZArchiveNode *r = _archive.root;
    [pairs addObject:@[SZLang(kLang_PropFiles, @"Files"), [NSString stringWithFormat:@"%llu", r.numFiles]]];
    [pairs addObject:@[SZLang(kLang_PropFolders, @"Folders"), [NSString stringWithFormat:@"%llu", r.numFolders]]];
    [pairs addObject:@[SZLang(kLang_PropSize, @"Size"), SZFormatSizeExact(r.size)]];
    [SZPropertiesController showProperties:pairs title:_archive.displayName icon:[self iconForName:_archive.displayName isDir:NO]];
    return;
  }

  NSString *path = sel.count ? sel[0].fsPath : _fsPath;
  if (!path)
    return;
  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSMutableArray *pairs = [NSMutableArray array];
  [pairs addObject:@[SZLang(1003, @"Path"), path]];
  if (attrs)
  {
    if (![attrs.fileType isEqualToString:NSFileTypeDirectory])
      [pairs addObject:@[SZLang(kLang_PropSize, @"Size"), [NSString stringWithFormat:@"%@ (%@ bytes)",
          SZFormatSize([attrs fileSize]), SZFormatSizeExact([attrs fileSize])]]];
    if (attrs.fileModificationDate)
      [pairs addObject:@[SZLang(kLang_PropMTime, @"Modified"), SZFormatDate(attrs.fileModificationDate)]];
    if (attrs.fileCreationDate)
      [pairs addObject:@[SZLang(kLang_PropCTime, @"Created"), SZFormatDate(attrs.fileCreationDate)]];
    [pairs addObject:@[SZLang(1053, @"Mode"), SZFormatAttrib((uint32_t)(([attrs filePosixPermissions] |
        ([attrs.fileType isEqualToString:NSFileTypeDirectory] ? 0040000 : 0100000)) << 16) | 0x8000)]];
    if (attrs.fileOwnerAccountName)
      [pairs addObject:@[SZLang(1025, @"User"), attrs.fileOwnerAccountName]];
    if (attrs.fileGroupOwnerAccountName)
      [pairs addObject:@[SZLang(1026, @"Group"), attrs.fileGroupOwnerAccountName]];
  }
  NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
  [SZPropertiesController showProperties:pairs title:path.lastPathComponent icon:icon];
}

- (IBAction)showInFinder:(id)sender
{
  NSArray *paths = [self selectedPaths];
  if (paths.count)
  {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in paths)
      [urls addObject:[NSURL fileURLWithPath:p]];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
  }
  else
  {
    SZArchive *outer = _archive;
    while (outer.parentArchive)
      outer = outer.parentArchive;
    NSString *p = outer ? outer.path : _fsPath;
    if (p)
      [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:p]]];
  }
}

- (IBAction)copyPath:(id)sender
{
  NSMutableArray *lines = [NSMutableArray array];
  for (SZListItem *i in [self clickedOrSelectedItems])
    [lines addObject:i.fsPath ?: [i.node pathInArchive]];
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (IBAction)refresh:(id)sender
{
  NSSet *selected = [NSSet setWithArray:[[self selectedItems] valueForKey:@"name"]];
  if (_archive)
  {
    [self reopenArchiveSelecting:selected];
    return;
  }
  [self reloadSidebar];
  [self reloadItems];
  [self selectNames:selected];
}

- (IBAction)toggleHidden:(id)sender
{
  _showHidden = !_showHidden;
  [[NSUserDefaults standardUserDefaults] setBool:_showHidden forKey:kKey_ShowHidden];
  [self reloadItems];
}

- (IBAction)invertSelection:(id)sender
{
  NSMutableIndexSet *set = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _items.count)];
  [set removeIndexes:_table.selectedRowIndexes];
  [_table selectRowIndexes:set byExtendingSelection:NO];
}

- (IBAction)selectAll:(id)sender
{
  [_table selectAll:sender];
}

- (IBAction)deselectAll:(id)sender
{
  [_table deselectAll:sender];
}

- (IBAction)openDocument:(id)sender
{
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES;
  p.canChooseDirectories = YES;
  if (_fsPath)
    p.directoryURL = [NSURL fileURLWithPath:_fsPath];
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK)
      [self navigateToPath:p.URL.path];
  }];
}

// ---------- menus ----------

- (void)menuNeedsUpdate:(NSMenu *)menu
{
  [menu removeAllItems];
  if ([menu.identifier isEqualToString:@"header"])
  {
    NSSet *hidden = [self hiddenColumns];
    for (NSTableColumn *c in _table.tableColumns)
    {
      if ([c.identifier isEqualToString:kCol_Name])
        continue;
      NSMenuItem *mi = [menu addItemWithTitle:c.title action:@selector(toggleColumn:) keyEquivalent:@""];
      mi.target = self;
      mi.representedObject = c.identifier;
      mi.state = [hidden containsObject:c.identifier] ? NSControlStateValueOff : NSControlStateValueOn;
    }
    return;
  }

  // context menu
  NSArray<SZListItem *> *sel = [self clickedOrSelectedItems];
  const BOOL arc = [self inArchive];
  auto add = ^NSMenuItem *(NSString *title, SEL action, NSString *symbol) {
    NSMenuItem *mi = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    mi.target = self;
    if (symbol)
      mi.image = SZSymbol(symbol, 0);
    return mi;
  };
  if (sel.count)
  {
    add(SZStripAmp(SZLang(kLang_Open, @"Open")), @selector(openSelected:), nil);
    if (sel.count == 1 && !sel[0].isDir)
      add(SZStripAmp(SZLang(kLang_OpenInside, @"Open Inside")), @selector(openInside:), nil);
    add(SZStripAmp(SZLang(kLang_OpenOutside, @"Open Outside")), @selector(openOutside:), nil);
    if (!arc)
      add(@"Show in Finder", @selector(showInFinder:), @"folder");
    [menu addItem:[NSMenuItem separatorItem]];
  }
  if (!arc && sel.count)
  {
    NSMenuItem *sub = [menu addItemWithTitle:@"7-Zip" action:nil keyEquivalent:@""];
    sub.image = [NSImage imageNamed:NSImageNameApplicationIcon];
    sub.image.size = NSMakeSize(16, 16);
    NSMenu *m = [[NSMenu alloc] init];
    NSArray *paths = [self selectedPaths];
    BOOL anyArchive = NO;
    for (NSString *p in paths)
      if (SZIsArchivePath(p))
        anyArchive = YES;
    // the names are same as in context menu of 7-Zip in Windows Explorer
    if (anyArchive)
    {
      NSString *folder = paths.count == 1 ?
          [NSString stringWithFormat:@"\"%@/\"", [((NSString *)paths[0]).lastPathComponent stringByDeletingPathExtension]] : @"*/";
      [m addItemWithTitle:SZStripAmp(SZLang(kLang_CtxExtract, @"Extract files...")) action:@selector(extractFiles:) keyEquivalent:@""].target = self;
      [m addItemWithTitle:SZStripAmp(SZLang(kLang_CtxExtractHere, @"Extract Here")) action:@selector(extractHere:) keyEquivalent:@""].target = self;
      [m addItemWithTitle:SZLangFormat(kLang_CtxExtractTo, @"Extract to {0}", folder) action:@selector(extractToFolder:) keyEquivalent:@""].target = self;
      [m addItemWithTitle:SZStripAmp(SZLang(kLang_CtxTest, @"Test archive")) action:@selector(testFiles:) keyEquivalent:@""].target = self;
      [m addItem:[NSMenuItem separatorItem]];
    }
    [m addItemWithTitle:SZStripAmp(SZLang(kLang_CtxCompress, @"Add to archive...")) action:@selector(addFiles:) keyEquivalent:@""].target = self;
    NSString *base = [[SZCompressController defaultArchivePathForFiles:paths extension:@"7z"] lastPathComponent];
    NSString *baseZip = [[SZCompressController defaultArchivePathForFiles:paths extension:@"zip"] lastPathComponent];
    [m addItemWithTitle:SZLangFormat(kLang_CtxCompressTo, @"Add to {0}", [NSString stringWithFormat:@"\"%@\"", base]) action:@selector(compressTo7z:) keyEquivalent:@""].target = self;
    [m addItemWithTitle:SZLangFormat(kLang_CtxCompressTo, @"Add to {0}", [NSString stringWithFormat:@"\"%@\"", baseZip]) action:@selector(compressToZip:) keyEquivalent:@""].target = self;
    sub.submenu = m;
    [menu addItem:[NSMenuItem separatorItem]];
  }
  if (arc)
  {
    add(SZStripAmp(SZLang(kLang_Extract, @"Extract")), @selector(extractFiles:), @"minus.circle");
    add(SZStripAmp(SZLang(kLang_Test, @"Test")), @selector(testFiles:), @"checkmark.circle");
    [menu addItem:[NSMenuItem separatorItem]];
  }
  if (sel.count)
  {
    add(SZStripAmp(SZLang(kLang_Rename, @"Rename")), @selector(renameItem:), @"pencil");
    add(SZStripAmp(SZLang(kLang_Delete, @"Delete")), @selector(deleteFiles:), @"trash");
    add(@"Copy Path", @selector(copyPath:), @"doc.on.doc");
    [menu addItem:[NSMenuItem separatorItem]];
  }
  else if (!arc)
  {
    add(SZStripAmp(SZLang(kLang_CreateFolder, @"Create Folder")), @selector(createFolder:), @"folder.badge.plus");
    [menu addItem:[NSMenuItem separatorItem]];
  }
  add(SZStripAmp(SZLang(kLang_Properties, @"Properties")), @selector(showInfo:), @"info.circle");
}

- (void)toggleColumn:(NSMenuItem *)item
{
  NSMutableSet *hidden = [[self hiddenColumns] mutableCopy];
  NSString *ident = item.representedObject;
  if ([hidden containsObject:ident])
    [hidden removeObject:ident];
  else
    [hidden addObject:ident];
  [[NSUserDefaults standardUserDefaults] setObject:hidden.allObjects forKey:kKey_HiddenColumns];
  [self updateColumnsVisibility];
}

// ---------- window ----------

- (void)windowWillClose:(NSNotification *)notification
{
  [g_Browsers removeObject:self];
}

@end
