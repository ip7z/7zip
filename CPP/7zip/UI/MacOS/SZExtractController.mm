// SZExtractController.mm

#import "SZExtractController.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZUtils.h"

using namespace NMacEngine;

static NSString * const kKey_PathHistory = @"Extract.PathHistory";
static NSString * const kKey_PathMode = @"Extract.PathMode";
static NSString * const kKey_OverwriteMode = @"Extract.OverwriteMode";
static NSString * const kKey_ElimDup = @"Extract.ElimDup";
static NSString * const kKey_Subfolder = @"Extract.Subfolder";

static const unsigned kHistorySize = 16;

@implementation SZExtractOptions
@end


@interface SZExtractController () <NSWindowDelegate>
@property (copy) void (^completion)(SZExtractOptions *);
@end

static NSMutableSet *g_OpenControllers;

@implementation SZExtractController
{
  NSComboBox *_pathCombo;
  NSButton *_subfolderCheck;
  NSTextField *_subfolderField;
  NSPopUpButton *_pathModePopup;
  NSPopUpButton *_overwritePopup;
  NSButton *_elimDupCheck;
  NSSecureTextField *_passwordField;
  NSTextField *_passwordPlain;
  NSButton *_showPasswordCheck;
  BOOL _hasSubfolder;
}

+ (void)showWithDirectory:(NSString *)dir
                subfolder:(NSString *)subfolder
              showElimDup:(BOOL)showElimDup
                   parent:(NSWindow *)parent
               completion:(void (^)(SZExtractOptions *options))completion
{
  SZExtractController *c = [[SZExtractController alloc] initWithDirectory:dir subfolder:subfolder showElimDup:showElimDup];
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

- (instancetype)initWithDirectory:(NSString *)dir subfolder:(NSString *)subfolder showElimDup:(BOOL)showElimDup
{
  NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 300)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
      backing:NSBackingStoreBuffered defer:YES];
  w.releasedWhenClosed = NO;
  w.title = SZStripAmp(SZLang(kLang_ExtractTitle, @"Extract"));
  self = [super initWithWindow:w];
  if (!self)
    return nil;
  w.delegate = self;
  _hasSubfolder = (subfolder != nil);
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

  // ---- Extract to ----
  NSTextField *extractTo = SZLabel(SZStripAmp(SZLang(kLang_ExtractTo, @"Extract to:")));
  _pathCombo = [[NSComboBox alloc] init];
  _pathCombo.completes = NO;
  _pathCombo.numberOfVisibleItems = 10;
  [_pathCombo addItemWithObjectValue:dir];
  for (NSString *h in [d stringArrayForKey:kKey_PathHistory])
    if (![h isEqualToString:dir])
      [_pathCombo addItemWithObjectValue:h];
  _pathCombo.stringValue = dir;
  ((NSComboBoxCell *)_pathCombo.cell).lineBreakMode = NSLineBreakByTruncatingHead;
  NSButton *browse = SZPushButton(@"…", self, @selector(browse:));
  browse.toolTip = SZLang(kLang_ExtractSetFolder, @"Specify a location for extracted files.");
  NSStackView *pathRow = [NSStackView stackViewWithViews:@[_pathCombo, browse]];
  [_pathCombo setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSMutableArray *views = [NSMutableArray arrayWithObjects:extractTo, pathRow, nil];

  if (_hasSubfolder)
  {
    _subfolderCheck = SZCheckbox(@"", [d objectForKey:kKey_Subfolder] ? [d boolForKey:kKey_Subfolder] : YES);
    _subfolderCheck.target = self;
    _subfolderCheck.action = @selector(subfolderToggled:);
    _subfolderField = [[NSTextField alloc] init];
    _subfolderField.stringValue = subfolder;
    _subfolderField.enabled = (_subfolderCheck.state == NSControlStateValueOn);
    NSStackView *subRow = [NSStackView stackViewWithViews:@[_subfolderCheck, _subfolderField]];
    [_subfolderField setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [views addObject:subRow];
  }

  // ---- modes ----
  _pathModePopup = SZPopUp(@[
    SZLang(kLang_PathsFull, @"Full pathnames"),
    SZLang(kLang_PathsNo, @"No pathnames"),
    SZLang(kLang_PathsAbs, @"Absolute pathnames")
  ]);
  _pathModePopup.itemArray[0].tag = kPathMode_Full;
  _pathModePopup.itemArray[1].tag = kPathMode_No;
  _pathModePopup.itemArray[2].tag = kPathMode_Abs;
  [_pathModePopup selectItemWithTag:[d integerForKey:kKey_PathMode]];

  _overwritePopup = SZPopUp(@[
    SZLang(kLang_OverwriteAsk, @"Ask before overwrite"),
    SZLang(kLang_OverwriteWithoutPrompt, @"Overwrite without prompt"),
    SZLang(kLang_OverwriteSkip, @"Skip existing files"),
    SZLang(kLang_OverwriteRename, @"Auto rename"),
    SZLang(kLang_OverwriteRenameExisting, @"Auto rename existing files")
  ]);
  for (NSInteger i = 0; i < 5; i++)
    _overwritePopup.itemArray[i].tag = i;
  [_overwritePopup selectItemWithTag:[d integerForKey:kKey_OverwriteMode]];

  NSGridView *modes = [NSGridView gridViewWithViews:@[
    @[SZLabel(SZStripAmp(SZLang(kLang_PathMode, @"Path mode:"))), _pathModePopup],
    @[SZLabel(SZStripAmp(SZLang(kLang_OverwriteMode, @"Overwrite mode:"))), _overwritePopup],
  ]];
  modes.rowSpacing = 8;
  [modes columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [modes rowAtIndex:0].yPlacement = NSGridCellPlacementCenter;
  [modes rowAtIndex:1].yPlacement = NSGridCellPlacementCenter;
  SZHug(modes);
  [views addObject:modes];

  if (showElimDup)
  {
    _elimDupCheck = SZCheckbox(SZStripAmp(SZLang(kLang_ElimDup, @"Eliminate duplication of root folder")),
        [d objectForKey:kKey_ElimDup] ? [d boolForKey:kKey_ElimDup] : YES);
    [views addObject:_elimDupCheck];
  }

  // ---- password ----
  _passwordField = [[NSSecureTextField alloc] init];
  _passwordPlain = [[NSTextField alloc] init];
  _passwordPlain.hidden = YES;
  _showPasswordCheck = SZCheckbox(SZStripAmp(SZLang(kLang_PasswordShow, @"Show password")), NO);
  _showPasswordCheck.target = self;
  _showPasswordCheck.action = @selector(showPasswordToggled:);
  NSStackView *pwRow = [NSStackView stackViewWithViews:@[
      SZLabel(SZStripAmp(SZLang(kLang_PasswordGroup, @"Password"))), _passwordField, _passwordPlain, _showPasswordCheck]];
  [_passwordField.widthAnchor constraintEqualToConstant:200].active = YES;
  [_passwordPlain.widthAnchor constraintEqualToConstant:200].active = YES;
  [views addObject:SZSeparator()];
  [views addObject:pwRow];

  // ---- buttons ----
  NSButton *ok = SZPushButton(SZLang(kLang_OK, @"OK"), self, @selector(okClicked:));
  ok.keyEquivalent = @"\r";
  NSButton *cancel = SZPushButton(SZLang(kLang_Cancel, @"Cancel"), self, @selector(cancelClicked:));
  cancel.keyEquivalent = @"\033";
  [ok.widthAnchor constraintGreaterThanOrEqualToConstant:90].active = YES;
  [cancel.widthAnchor constraintGreaterThanOrEqualToConstant:90].active = YES;
  NSView *spacer = [[NSView alloc] init];
  [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *buttons = [NSStackView stackViewWithViews:@[spacer, cancel, ok]];
  [views addObject:buttons];

  NSStackView *main = [NSStackView stackViewWithViews:views];
  main.orientation = NSUserInterfaceLayoutOrientationVertical;
  main.alignment = NSLayoutAttributeLeading;
  main.spacing = 10;
  [main setCustomSpacing:4 afterView:extractTo];
  [main setCustomSpacing:18 afterView:pwRow];
  main.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
  main.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *content = w.contentView;
  [content addSubview:main];
  NSMutableArray *cons = [NSMutableArray arrayWithArray:@[
    [main.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [main.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [main.topAnchor constraintEqualToAnchor:content.topAnchor],
    [main.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [content.widthAnchor constraintEqualToConstant:560],
    [pathRow.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-40],
    [buttons.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-40],
  ]];
  if (_hasSubfolder)
    [cons addObject:[_subfolderField.superview.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-40]];
  [NSLayoutConstraint activateConstraints:cons];
  SZFitWindow(w, main);
  w.initialFirstResponder = ok;
  return self;
}

- (void)browse:(id)sender
{
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseDirectories = YES;
  p.canChooseFiles = NO;
  p.canCreateDirectories = YES;
  p.prompt = SZLang(kLang_OK, @"OK");
  p.message = SZLang(kLang_ExtractSetFolder, @"Specify a location for extracted files.");
  NSString *cur = [_pathCombo.stringValue stringByExpandingTildeInPath];
  if (cur.length)
    p.directoryURL = [NSURL fileURLWithPath:cur isDirectory:YES];
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK)
      self->_pathCombo.stringValue = p.URL.path;
  }];
}

- (void)subfolderToggled:(id)sender
{
  _subfolderField.enabled = (_subfolderCheck.state == NSControlStateValueOn);
}

- (void)showPasswordToggled:(id)sender
{
  const BOOL show = (_showPasswordCheck.state == NSControlStateValueOn);
  if (show)
    _passwordPlain.stringValue = _passwordField.stringValue;
  else
    _passwordField.stringValue = _passwordPlain.stringValue;
  _passwordPlain.hidden = !show;
  _passwordField.hidden = show;
}

- (void)closeWithOptions:(SZExtractOptions *)opts
{
  if (self.window.sheetParent)
    [self.window.sheetParent endSheet:self.window];
  else
    [self.window orderOut:nil];
  void (^c)(SZExtractOptions *) = _completion;
  _completion = nil;
  [g_OpenControllers removeObject:self];
  if (c)
    c(opts);
}

- (void)okClicked:(id)sender
{
  NSString *dir = [[_pathCombo.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] stringByExpandingTildeInPath];
  if (dir.length == 0)
  {
    NSBeep();
    return;
  }
  SZExtractOptions *o = [[SZExtractOptions alloc] init];
  o.baseDir = dir;
  o.outputDir = dir;
  if (_hasSubfolder && _subfolderCheck.state == NSControlStateValueOn)
  {
    NSString *sub = [_subfolderField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (sub.length)
    {
      o.subfolder = sub;
      o.outputDir = [dir stringByAppendingPathComponent:sub];
    }
  }
  o.pathMode = (EPathMode)_pathModePopup.selectedTag;
  o.overwriteMode = (EOverwriteMode)_overwritePopup.selectedTag;
  o.elimDup = _elimDupCheck ? (_elimDupCheck.state == NSControlStateValueOn) : NO;
  NSString *pw = (_showPasswordCheck.state == NSControlStateValueOn) ? _passwordPlain.stringValue : _passwordField.stringValue;
  o.password = pw.length ? pw : nil;

  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSMutableArray *history = [NSMutableArray arrayWithObject:dir];
  for (NSString *h in [d stringArrayForKey:kKey_PathHistory])
    if (![h isEqualToString:dir] && history.count < kHistorySize)
      [history addObject:h];
  [d setObject:history forKey:kKey_PathHistory];
  [d setInteger:o.pathMode forKey:kKey_PathMode];
  [d setInteger:o.overwriteMode forKey:kKey_OverwriteMode];
  if (_elimDupCheck)
    [d setBool:o.elimDup forKey:kKey_ElimDup];
  if (_hasSubfolder)
    [d setBool:(_subfolderCheck.state == NSControlStateValueOn) forKey:kKey_Subfolder];

  [self closeWithOptions:o];
}

- (void)cancelClicked:(id)sender
{
  [self closeWithOptions:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
  [self closeWithOptions:nil];
  return NO;
}

@end
