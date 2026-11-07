// SZPropertiesController.mm

#import "SZPropertiesController.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZUtils.h"

static NSMutableSet *g_OpenWindows;

@interface SZPropertiesController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@end

@implementation SZPropertiesController
{
  NSArray<NSArray<NSString *> *> *_pairs;
  NSTableView *_table;
}

+ (void)showProperties:(NSArray<NSArray<NSString *> *> *)pairs title:(NSString *)title icon:(NSImage *)icon
{
  SZPropertiesController *c = [[SZPropertiesController alloc] initWithPairs:pairs title:title icon:icon];
  if (!g_OpenWindows)
    g_OpenWindows = [NSMutableSet set];
  [g_OpenWindows addObject:c];
  NSWindow *key = [NSApp keyWindow];
  if (key)
  {
    NSPoint p = key.frame.origin;
    [c.window setFrameTopLeftPoint:NSMakePoint(p.x + 60, NSMaxY(key.frame) - 60)];
  }
  else
    [c.window center];
  [c showWindow:nil];
}

- (instancetype)initWithPairs:(NSArray<NSArray<NSString *> *> *)pairs title:(NSString *)title icon:(NSImage *)icon
{
  NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 420)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
      backing:NSBackingStoreBuffered defer:YES];
  w.releasedWhenClosed = NO;
  w.title = [NSString stringWithFormat:@"%@ — %@", SZStripAmp(SZLang(kLang_PropertiesTitle, @"Properties")), title];
  w.minSize = NSMakeSize(320, 200);
  w.hidesOnDeactivate = NO;
  self = [super initWithWindow:w];
  if (!self)
    return nil;
  w.delegate = self;
  _pairs = [pairs copy];

  NSImageView *iv = [NSImageView imageViewWithImage:icon ?: SZSymbol(@"doc", 32)];
  [iv.widthAnchor constraintEqualToConstant:40].active = YES;
  [iv.heightAnchor constraintEqualToConstant:40].active = YES;
  NSTextField *name = SZBoldLabel(title);
  name.font = [NSFont boldSystemFontOfSize:15];
  NSStackView *header = [NSStackView stackViewWithViews:@[iv, name]];
  header.spacing = 10;

  _table = [[NSTableView alloc] init];
  NSTableColumn *c1 = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  c1.title = @"";
  c1.width = 150;
  NSTableColumn *c2 = [[NSTableColumn alloc] initWithIdentifier:@"value"];
  c2.title = @"";
  c2.width = 260;
  [_table addTableColumn:c1];
  [_table addTableColumn:c2];
  _table.headerView = nil;
  _table.dataSource = self;
  _table.delegate = self;
  _table.usesAlternatingRowBackgroundColors = YES;
  _table.style = NSTableViewStyleFullWidth;
  _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
  _table.allowsMultipleSelection = YES;

  NSScrollView *scroll = [[NSScrollView alloc] init];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;

  NSStackView *main = [NSStackView stackViewWithViews:@[header, scroll]];
  main.orientation = NSUserInterfaceLayoutOrientationVertical;
  main.alignment = NSLayoutAttributeLeading;
  main.spacing = 12;
  main.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
  main.translatesAutoresizingMaskIntoConstraints = NO;
  NSView *content = w.contentView;
  [content addSubview:main];
  [NSLayoutConstraint activateConstraints:@[
    [main.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [main.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [main.topAnchor constraintEqualToAnchor:content.topAnchor],
    [main.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [scroll.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-32],
  ]];
  return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  return (NSInteger)_pairs.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
  const BOOL isName = [col.identifier isEqualToString:@"name"];
  NSTextField *t = [tableView makeViewWithIdentifier:col.identifier owner:self];
  if (!t)
  {
    t = [NSTextField labelWithString:@""];
    t.identifier = col.identifier;
    t.selectable = YES;
    t.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (isName)
      t.textColor = [NSColor secondaryLabelColor];
  }
  NSArray<NSString *> *p = _pairs[(NSUInteger)row];
  t.stringValue = isName ? p[0] : p[1];
  t.toolTip = isName ? nil : p[1];
  return t;
}

- (void)copy:(id)sender
{
  NSMutableArray *lines = [NSMutableArray array];
  NSIndexSet *rows = _table.selectedRowIndexes.count ? _table.selectedRowIndexes :
      [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _pairs.count)];
  [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    [lines addObject:[NSString stringWithFormat:@"%@ = %@", self->_pairs[i][0], self->_pairs[i][1]]];
  }];
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (void)windowWillClose:(NSNotification *)notification
{
  [g_OpenWindows removeObject:self];
}

@end
