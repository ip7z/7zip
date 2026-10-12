// AppDelegate.mm

#import "AppDelegate.h"
#import "SZBrowserController.h"
#import "SZCommands.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZUtils.h"

#include "MacEngine.h"

static NSString * const kKey_LastFolder = @"Browser.LastFolder";

@implementation AppDelegate
{
  BOOL _openedFiles;
  NSInteger _serviceOperations;
  BOOL _launchedForService;
  BOOL _servicesCalled;
  NSWindow *_settingsWindow;
}

// ---------- application ----------

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
  if (!SZLangInit())
  {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"7-Zip cannot load codecs";
    [a runModal];
    [NSApp terminate:nil];
    return;
  }
  [NSApp setServicesProvider:self];
  [self buildMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  // If 7-Zip was started by Finder service or for documents, it's not default launch.
  // Then we don't open browser window, and we quit after service operation.
  const BOOL isDefaultLaunch = [notification.userInfo[NSApplicationLaunchIsDefaultLaunchKey] boolValue];
  if (!isDefaultLaunch)
    _launchedForService = YES;
  const double delay = isDefaultLaunch ? 0 : 1.5;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (self->_openedFiles || self->_serviceOperations != 0 || self->_servicesCalled
        || [SZBrowserController allBrowsers].count != 0)
      return;
    self->_launchedForService = NO;
    [self newWindow:nil];
  });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
  return YES;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
  if (!flag)
    [self newWindow:nil];
  return YES;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls
{
  _openedFiles = YES;
  for (NSURL *u in urls)
    if (u.isFileURL)
      [SZBrowserController openWindowWithPath:u.path];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
  [[NSFileManager defaultManager] removeItemAtPath:SZTempFolder() error:nil];
}

// ---------- actions ----------

- (IBAction)newWindow:(id)sender
{
  NSString *folder = [[NSUserDefaults standardUserDefaults] stringForKey:kKey_LastFolder];
  BOOL isDir = NO;
  if (!folder || ![[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&isDir] || !isDir)
    folder = NSHomeDirectory();
  [SZBrowserController openWindowWithPath:folder];
}

- (IBAction)openDocument:(id)sender
{
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES;
  p.canChooseDirectories = YES;
  p.allowsMultipleSelection = YES;
  if ([p runModal] == NSModalResponseOK)
    for (NSURL *u in p.URLs)
      [SZBrowserController openWindowWithPath:u.path];
}

- (IBAction)showAbout:(id)sender
{
  NSString *version = [NSString stringWithFormat:@"%s (%s)", NMacEngine::GetVersion(), NMacEngine::GetDate()];
  NSMutableAttributedString *credits = [[NSMutableAttributedString alloc] init];
  NSDictionary *attrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:[NSFont smallSystemFontSize]],
    NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
  };
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentCenter;
  NSString *text = [NSString stringWithFormat:@"%s\n\n%@\n\n", NMacEngine::GetCopyright(),
      SZLang(kLang_AboutInfo, @"7-Zip is free software")];
  [credits appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
  NSMutableDictionary *linkAttrs = [attrs mutableCopy];
  linkAttrs[NSLinkAttributeName] = [NSURL URLWithString:@"https://www.7-zip.org/"];
  [credits appendAttributedString:[[NSAttributedString alloc] initWithString:@"www.7-zip.org" attributes:linkAttrs]];
  [credits addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, credits.length)];
  [NSApp orderFrontStandardAboutPanelWithOptions:@{
    NSAboutPanelOptionApplicationName: @"7-Zip",
    NSAboutPanelOptionApplicationVersion: version,
    NSAboutPanelOptionVersion: @"",
    NSAboutPanelOptionCredits: credits,
  }];
}

- (IBAction)showHelp:(id)sender
{
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://www.7-zip.org/faq.html"]];
}

- (IBAction)showHomePage:(id)sender
{
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://www.7-zip.org/"]];
}

// ---------- settings ----------

- (IBAction)showSettings:(id)sender
{
  if (_settingsWindow)
  {
    [_settingsWindow makeKeyAndOrderFront:nil];
    return;
  }
  NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 140)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
  w.releasedWhenClosed = NO;
  w.title = SZStripAmp(SZLang(kLang_Options, @"Options"));

  NSPopUpButton *lang = SZPopUp(@[]);
  [lang addItemWithTitle:@"System default"];
  lang.lastItem.representedObject = @"";
  [lang addItemWithTitle:@"English"];
  lang.lastItem.representedObject = @"-";
  NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:SZLangDefaultsKey] ?: @"";
  for (NSString *code in SZLangAvailableCodes())
  {
    [lang addItemWithTitle:code];
    lang.lastItem.representedObject = code;
  }
  for (NSMenuItem *mi in lang.itemArray)
    if ([mi.representedObject isEqualToString:current])
      [lang selectItem:mi];
  lang.target = self;
  lang.action = @selector(languageChanged:);

  NSTextField *note = SZSecondaryLabel(SZLangAvailableCodes().count ?
      @"The change will be applied after restart of 7-Zip." :
      @"There are no lang files in 7-Zip.app/Contents/Resources/Lang.");
  note.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];

  NSGridView *g = SZFormGrid(@[@[SZLabel(@"Language:"), lang], @[[NSGridCell emptyContentView], note]]);
  [w.contentView addSubview:g];
  [NSLayoutConstraint activateConstraints:@[
    [g.centerXAnchor constraintEqualToAnchor:w.contentView.centerXAnchor],
    [g.centerYAnchor constraintEqualToAnchor:w.contentView.centerYAnchor],
  ]];
  [w center];
  _settingsWindow = w;
  [w makeKeyAndOrderFront:nil];
}

- (void)languageChanged:(NSPopUpButton *)sender
{
  NSString *code = sender.selectedItem.representedObject;
  if (code.length)
    [[NSUserDefaults standardUserDefaults] setObject:code forKey:SZLangDefaultsKey];
  else
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:SZLangDefaultsKey];
}

// ---------- Finder services ----------

static NSArray<NSString *> *FilesFromPasteboard(NSPasteboard *pb)
{
  NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSURL *u in urls)
    [paths addObject:u.path];
  return paths;
}

- (void)serviceStarted
{
  _servicesCalled = YES;
  _serviceOperations++;
  [NSApp activateIgnoringOtherApps:YES];
}

- (SZCommandCompletion)serviceCompletion
{
  return ^(BOOL ok) {
    self->_serviceOperations--;
    // if 7-Zip was started only for this service, we quit
    if (self->_serviceOperations == 0 && self->_launchedForService && [SZBrowserController allBrowsers].count == 0)
      [NSApp terminate:nil];
  };
}

- (void)compressFiles:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  NSArray *files = FilesFromPasteboard(pb);
  if (!files.count)
    return;
  [self serviceStarted];
  SZCompressFiles(files, nil, [self serviceCompletion]);
}

- (void)compressTo7z:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  NSArray *files = FilesFromPasteboard(pb);
  if (!files.count)
    return;
  [self serviceStarted];
  SZCompressFilesQuick(files, @"7z", nil, [self serviceCompletion]);
}

- (void)compressToZip:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  NSArray *files = FilesFromPasteboard(pb);
  if (!files.count)
    return;
  [self serviceStarted];
  SZCompressFilesQuick(files, @"zip", nil, [self serviceCompletion]);
}

- (void)extractFiles:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  NSArray *files = FilesFromPasteboard(pb);
  if (!files.count)
    return;
  [self serviceStarted];
  SZExtractArchives(files, SZExtractModeDialog, nil, [self serviceCompletion]);
}

- (void)extractHere:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  NSArray *files = FilesFromPasteboard(pb);
  if (!files.count)
    return;
  [self serviceStarted];
  SZExtractArchives(files, SZExtractModeHere, nil, [self serviceCompletion]);
}

- (void)extractToFolder:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  NSArray *files = FilesFromPasteboard(pb);
  if (!files.count)
    return;
  [self serviceStarted];
  SZExtractArchives(files, SZExtractModeToFolder, nil, [self serviceCompletion]);
}

- (void)testArchives:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  NSArray *files = FilesFromPasteboard(pb);
  if (!files.count)
    return;
  [self serviceStarted];
  SZTestArchives(files, nil, [self serviceCompletion]);
}

- (void)openArchive:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)error
{
  _openedFiles = YES;
  _launchedForService = NO;
  for (NSString *f in FilesFromPasteboard(pb))
    [SZBrowserController openWindowWithPath:f];
  [NSApp activateIgnoringOtherApps:YES];
}

// ---------- menu ----------

static NSMenuItem *AddItem(NSMenu *menu, NSString *title, SEL action, NSString *key, NSEventModifierFlags mods)
{
  NSMenuItem *mi = [menu addItemWithTitle:title action:action keyEquivalent:key ?: @""];
  if (key.length)
    mi.keyEquivalentModifierMask = mods;
  return mi;
}

static NSString *L(uint32_t langID, NSString *s)
{
  return SZStripAmp(SZLang(langID, s));
}

static NSString *KeyChar(unichar c)
{
  return [NSString stringWithCharacters:&c length:1];
}

- (void)buildMainMenu
{
  NSMenu *main = [[NSMenu alloc] init];
  const NSEventModifierFlags cmd = NSEventModifierFlagCommand;

  // application
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"7-Zip"];
  AddItem(appMenu, [NSString stringWithFormat:@"%@ 7-Zip", L(kLang_About, @"About")], @selector(showAbout:), nil, 0).target = self;
  [appMenu addItem:[NSMenuItem separatorItem]];
  AddItem(appMenu, [L(kLang_Options, @"Options") stringByAppendingString:@"…"], @selector(showSettings:), @",", cmd).target = self;
  [appMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *services = AddItem(appMenu, @"Services", nil, nil, 0);
  services.submenu = [[NSMenu alloc] init];
  NSApp.servicesMenu = services.submenu;
  [appMenu addItem:[NSMenuItem separatorItem]];
  AddItem(appMenu, @"Hide 7-Zip", @selector(hide:), @"h", cmd);
  AddItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h", cmd | NSEventModifierFlagOption);
  AddItem(appMenu, @"Show All", @selector(unhideAllApplications:), nil, 0);
  [appMenu addItem:[NSMenuItem separatorItem]];
  AddItem(appMenu, @"Quit 7-Zip", @selector(terminate:), @"q", cmd);
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = appMenu;

  // file
  NSMenu *file = [[NSMenu alloc] initWithTitle:L(kLang_MenuFile, @"File")];
  AddItem(file, @"New Window", @selector(newWindow:), @"n", cmd).target = self;
  AddItem(file, [L(kLang_Open, @"Open") stringByAppendingString:@"…"], @selector(openDocument:), @"o", cmd);
  [file addItem:[NSMenuItem separatorItem]];
  AddItem(file, L(kLang_Open, @"Open"), @selector(openSelected:), KeyChar(NSDownArrowFunctionKey), cmd);
  AddItem(file, L(kLang_OpenInside, @"Open Inside"), @selector(openInside:), KeyChar(NSPageDownFunctionKey), cmd);
  AddItem(file, L(kLang_OpenOutside, @"Open Outside"), @selector(openOutside:), KeyChar(NSDownArrowFunctionKey), cmd | NSEventModifierFlagShift);
  [file addItem:[NSMenuItem separatorItem]];
  AddItem(file, [L(kLang_AddToArchive, @"Add to Archive") stringByAppendingString:@"…"], @selector(addFiles:), @"a", cmd | NSEventModifierFlagShift);
  AddItem(file, [L(kLang_Extract, @"Extract") stringByAppendingString:@"…"], @selector(extractFiles:), @"e", cmd);
  AddItem(file, L(kLang_Test, @"Test"), @selector(testFiles:), @"t", cmd);
  [file addItem:[NSMenuItem separatorItem]];
  AddItem(file, L(kLang_Rename, @"Rename"), @selector(renameItem:), KeyChar(NSF2FunctionKey), 0);
  AddItem(file, L(kLang_CreateFolder, @"Create Folder"), @selector(createFolder:), @"n", cmd | NSEventModifierFlagShift);
  AddItem(file, L(kLang_Delete, @"Delete"), @selector(deleteFiles:), KeyChar(NSBackspaceCharacter), cmd);
  [file addItem:[NSMenuItem separatorItem]];
  AddItem(file, L(kLang_Properties, @"Properties"), @selector(showInfo:), @"i", cmd);
  AddItem(file, @"Show in Finder", @selector(showInFinder:), @"r", cmd | NSEventModifierFlagShift);
  [file addItem:[NSMenuItem separatorItem]];
  AddItem(file, @"Close", @selector(performClose:), @"w", cmd);
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = file;

  // edit
  NSMenu *edit = [[NSMenu alloc] initWithTitle:L(kLang_MenuEdit, @"Edit")];
  AddItem(edit, @"Cut", @selector(cut:), @"x", cmd);
  AddItem(edit, @"Copy", @selector(copy:), @"c", cmd);
  AddItem(edit, @"Paste", @selector(paste:), @"v", cmd);
  [edit addItem:[NSMenuItem separatorItem]];
  AddItem(edit, L(kLang_SelectAll, @"Select All"), @selector(selectAll:), @"a", cmd);
  AddItem(edit, L(kLang_DeselectAll, @"Deselect All"), @selector(deselectAll:), @"a", cmd | NSEventModifierFlagOption);
  AddItem(edit, L(kLang_InvertSelection, @"Invert Selection"), @selector(invertSelection:), @"i", cmd | NSEventModifierFlagOption);
  [edit addItem:[NSMenuItem separatorItem]];
  AddItem(edit, @"Copy Path", @selector(copyPath:), @"c", cmd | NSEventModifierFlagOption);
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = edit;

  // view
  NSMenu *view = [[NSMenu alloc] initWithTitle:L(kLang_MenuView, @"View")];
  AddItem(view, L(kLang_Refresh, @"Refresh"), @selector(refresh:), @"r", cmd);
  AddItem(view, @"Show Hidden Files", @selector(toggleHidden:), @".", cmd | NSEventModifierFlagShift);
  [view addItem:[NSMenuItem separatorItem]];
  AddItem(view, L(kLang_OpenParentFolder, @"Up One Level"), @selector(goUp:), KeyChar(NSUpArrowFunctionKey), cmd);
  AddItem(view, L(kLang_OpenRootFolder, @"Open Root Folder"), @selector(goRoot:), @"\\", cmd);
  AddItem(view, @"Back", @selector(goBack:), @"[", cmd);
  AddItem(view, @"Forward", @selector(goForward:), @"]", cmd);
  [view addItem:[NSMenuItem separatorItem]];
  AddItem(view, @"Show Sidebar", @selector(toggleSidebar:), @"s", cmd | NSEventModifierFlagControl);
  AddItem(view, @"Customize Toolbar…", @selector(runToolbarCustomizationPalette:), nil, 0);
  AddItem(view, @"Enter Full Screen", @selector(toggleFullScreen:), @"f", cmd | NSEventModifierFlagControl);
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = view;

  // window
  NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
  AddItem(window, @"Minimize", @selector(performMiniaturize:), @"m", cmd);
  AddItem(window, @"Zoom", @selector(performZoom:), nil, 0);
  [window addItem:[NSMenuItem separatorItem]];
  AddItem(window, @"Bring All to Front", @selector(arrangeInFront:), nil, 0);
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = window;
  NSApp.windowsMenu = window;

  // help
  NSMenu *help = [[NSMenu alloc] initWithTitle:L(kLang_MenuHelp, @"Help")];
  AddItem(help, L(kLang_HelpContents, @"Contents"), @selector(showHelp:), @"?", cmd).target = self;
  AddItem(help, @"7-Zip Home Page", @selector(showHomePage:), nil, 0).target = self;
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = help;
  NSApp.helpMenu = help;

  NSApp.mainMenu = main;
}

@end
