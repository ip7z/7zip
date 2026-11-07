// SZPrompts.mm

#import "SZPrompts.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZUtils.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

using namespace NMacEngine;

enum
{
  kLang_Yes = 406,
  kLang_No = 407
};

static void RunAlert(NSAlert *alert, NSWindow *window, void (^handler)(NSModalResponse r))
{
  if (window && window.isVisible && !window.attachedSheet)
    [alert beginSheetModalForWindow:window completionHandler:handler];
  else
    handler([alert runModal]);
}


// ---------- Password ----------

@interface SZPasswordAccessory : NSStackView
@property (strong) NSSecureTextField *secureField;
@property (strong) NSTextField *plainField;
@property (strong) NSButton *showCheck;
- (NSString *)password;
@end

@implementation SZPasswordAccessory

- (instancetype)init
{
  self = [super initWithFrame:NSMakeRect(0, 0, 300, 52)];
  if (self)
  {
    self.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.alignment = NSLayoutAttributeLeading;
    self.spacing = 8;
    _secureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 22)];
    _plainField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 22)];
    _plainField.hidden = YES;
    _showCheck = SZCheckbox(SZLang(kLang_PasswordShow, @"Show password"), NO);
    _showCheck.target = self;
    _showCheck.action = @selector(toggleShow:);
    [_secureField.widthAnchor constraintEqualToConstant:300].active = YES;
    [_plainField.widthAnchor constraintEqualToConstant:300].active = YES;
    [self addArrangedSubview:_secureField];
    [self addArrangedSubview:_plainField];
    [self addArrangedSubview:_showCheck];
  }
  return self;
}

- (void)toggleShow:(id)sender
{
  const BOOL show = (_showCheck.state == NSControlStateValueOn);
  if (show)
    _plainField.stringValue = _secureField.stringValue;
  else
    _secureField.stringValue = _plainField.stringValue;
  _plainField.hidden = !show;
  _secureField.hidden = show;
  [self.window makeFirstResponder:show ? _plainField : _secureField];
}

- (NSString *)password
{
  return (_showCheck.state == NSControlStateValueOn) ? _plainField.stringValue : _secureField.stringValue;
}

@end


void SZAskPassword(NSWindow *window, NSString *archiveName, void (^completion)(NSString *password))
{
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = SZLang(kLang_PasswordTitle, @"Enter password");
  if (archiveName.length)
    alert.informativeText = archiveName;
  alert.icon = SZSymbol(@"lock.fill", 40);
  [alert addButtonWithTitle:SZLang(kLang_OK, @"OK")];
  [alert addButtonWithTitle:SZLang(kLang_Cancel, @"Cancel")];
  SZPasswordAccessory *acc = [[SZPasswordAccessory alloc] init];
  alert.accessoryView = acc;
  alert.window.initialFirstResponder = acc.secureField;
  RunAlert(alert, window, ^(NSModalResponse r) {
    completion(r == NSAlertFirstButtonReturn ? [acc password] : nil);
  });
}


// ---------- Overwrite ----------

@interface SZOverwritePanel : NSObject
@property (strong) NSPanel *panel;
@property (copy) void (^completion)(EOverwriteAnswer);
@property (weak) NSWindow *parent;
@end

@implementation SZOverwritePanel

static NSView *FileView(SZFileDesc *d)
{
  NSImageView *icon = [NSImageView imageViewWithImage:
      [[NSFileManager defaultManager] fileExistsAtPath:d.path] ?
        [[NSWorkspace sharedWorkspace] iconForFile:d.path] :
        [[NSWorkspace sharedWorkspace] iconForContentType:
          [UTType typeWithFilenameExtension:d.path.pathExtension] ?: UTTypeData]];
  icon.imageScaling = NSImageScaleProportionallyUpOrDown;
  [icon.widthAnchor constraintEqualToConstant:48].active = YES;
  [icon.heightAnchor constraintEqualToConstant:48].active = YES;

  NSTextField *name = SZBoldLabel(d.path.lastPathComponent);
  name.toolTip = d.path;
  NSMutableArray *info = [NSMutableArray array];
  if (d.size)
  {
    const uint64_t size = d.size.unsignedLongLongValue;
    [info addObject:size < 1000 ? SZFormatSize(size) :
        [NSString stringWithFormat:@"%@ (%@ bytes)", SZFormatSize(size), SZFormatSizeExact(size)]];
  }
  if (d.date)
    [info addObject:SZFormatDate(d.date)];
  NSTextField *details = SZSecondaryLabel([info componentsJoinedByString:@"\n"]);
  details.maximumNumberOfLines = 2;

  NSStackView *text = [NSStackView stackViewWithViews:@[name, details]];
  text.orientation = NSUserInterfaceLayoutOrientationVertical;
  text.alignment = NSLayoutAttributeLeading;
  text.spacing = 2;

  NSStackView *row = [NSStackView stackViewWithViews:@[icon, text]];
  row.spacing = 12;
  row.edgeInsets = NSEdgeInsetsMake(0, 16, 0, 0);
  return row;
}

- (instancetype)initWithExisting:(SZFileDesc *)existing newFile:(SZFileDesc *)newFile
{
  self = [super init];
  if (!self)
    return nil;

  NSTextField *header = SZBoldLabel(SZLang(kLang_OverwriteDestContains, @"Destination folder already contains processed file."));
  NSTextField *q1 = SZLabel(SZLang(kLang_OverwriteQuestionBegin, @"Would you like to replace the existing file"));
  NSTextField *q2 = SZLabel(SZLang(kLang_OverwriteQuestionEnd, @"with this one?"));

  NSArray *titles = @[
    SZLang(kLang_Yes, @"Yes"),
    SZLang(kLang_YesToAll, @"Yes to All"),
    SZLang(kLang_No, @"No"),
    SZLang(kLang_NoToAll, @"No to All"),
    SZLang(kLang_AutoRename, @"Auto Rename"),
    SZLang(kLang_Cancel, @"Cancel")
  ];
  const EOverwriteAnswer answers[] = { kOverwrite_Yes, kOverwrite_YesToAll, kOverwrite_No,
      kOverwrite_NoToAll, kOverwrite_AutoRename, kOverwrite_Cancel };
  NSMutableArray *buttons = [NSMutableArray array];
  for (NSUInteger i = 0; i < titles.count; i++)
  {
    NSButton *b = SZPushButton(SZStripAmp(titles[i]), self, @selector(buttonClicked:));
    b.tag = answers[i];
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
    [buttons addObject:b];
  }
  ((NSButton *)buttons[0]).keyEquivalent = @"\r";
  ((NSButton *)buttons[5]).keyEquivalent = @"\033";

  NSStackView *row1 = [NSStackView stackViewWithViews:[buttons subarrayWithRange:NSMakeRange(0, 4)]];
  NSStackView *row2 = [NSStackView stackViewWithViews:[buttons subarrayWithRange:NSMakeRange(4, 2)]];

  NSView *existingView = FileView(existing);
  NSView *newView = FileView(newFile);
  NSStackView *main = [NSStackView stackViewWithViews:@[header, q1, existingView, q2, newView, row1, row2]];
  main.orientation = NSUserInterfaceLayoutOrientationVertical;
  main.alignment = NSLayoutAttributeLeading;
  main.spacing = 10;
  main.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
  main.translatesAutoresizingMaskIntoConstraints = NO;
  [main setCustomSpacing:14 afterView:header];
  [main setCustomSpacing:22 afterView:newView];
  row2.alignment = NSLayoutAttributeCenterY;

  _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 300)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  _panel.title = SZLang(kLang_OverwriteHeader, @"Confirm File Replace");
  [_panel.contentView addSubview:main];
  [NSLayoutConstraint activateConstraints:@[
    [main.leadingAnchor constraintEqualToAnchor:_panel.contentView.leadingAnchor],
    [main.trailingAnchor constraintEqualToAnchor:_panel.contentView.trailingAnchor],
    [main.topAnchor constraintEqualToAnchor:_panel.contentView.topAnchor],
    [main.bottomAnchor constraintEqualToAnchor:_panel.contentView.bottomAnchor],
  ]];
  SZFitWindow(_panel, main);
  return self;
}

- (void)buttonClicked:(NSButton *)sender
{
  const EOverwriteAnswer a = (EOverwriteAnswer)sender.tag;
  if (_panel.sheetParent)
    [_panel.sheetParent endSheet:_panel];
  else
  {
    [NSApp stopModal];
    [_panel orderOut:nil];
  }
  void (^c)(EOverwriteAnswer) = _completion;
  _completion = nil;
  if (c)
    c(a);
}

@end


void SZAskOverwrite(NSWindow *window, SZFileDesc *existing, SZFileDesc *newFile,
    void (^completion)(EOverwriteAnswer answer))
{
  static NSMutableSet *openPanels;
  if (!openPanels)
    openPanels = [NSMutableSet set];
  SZOverwritePanel *p = [[SZOverwritePanel alloc] initWithExisting:existing newFile:newFile];
  [openPanels addObject:p];
  __weak SZOverwritePanel *weakPanel = p;
  p.completion = ^(EOverwriteAnswer a) {
    completion(a);
    if (weakPanel)
      [openPanels removeObject:weakPanel];
  };
  if (window && window.isVisible && !window.attachedSheet)
    [window beginSheet:p.panel completionHandler:nil];
  else
  {
    [p.panel center];
    [NSApp runModalForWindow:p.panel];
  }
}


// ---------- Text ----------

void SZAskText(NSWindow *window, NSString *title, NSString *label, NSString *defaultText,
    void (^completion)(NSString *text))
{
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = title;
  alert.informativeText = label;
  [alert addButtonWithTitle:SZLang(kLang_OK, @"OK")];
  [alert addButtonWithTitle:SZLang(kLang_Cancel, @"Cancel")];
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 22)];
  field.stringValue = defaultText;
  alert.accessoryView = field;
  alert.window.initialFirstResponder = field;
  RunAlert(alert, window, ^(NSModalResponse r) {
    completion(r == NSAlertFirstButtonReturn ? field.stringValue : nil);
  });
}

void SZConfirm(NSWindow *window, NSString *title, NSString *message, NSString *okTitle,
    BOOL destructive, void (^completion)(BOOL ok))
{
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = title;
  alert.informativeText = message;
  alert.alertStyle = NSAlertStyleWarning;
  NSButton *ok = [alert addButtonWithTitle:okTitle];
  if (destructive)
    ok.hasDestructiveAction = YES;
  [alert addButtonWithTitle:SZLang(kLang_Cancel, @"Cancel")];
  RunAlert(alert, window, ^(NSModalResponse r) {
    completion(r == NSAlertFirstButtonReturn);
  });
}
