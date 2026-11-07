// SZUtils.mm

#import "SZUtils.h"

#include "MacEngine.h"

NSString *SZString(const char *utf8)
{
  if (!utf8)
    return @"";
  NSString *s = [NSString stringWithUTF8String:utf8];
  return s ? s : @"";
}

NSString *SZFormatSize(uint64_t size)
{
  static NSByteCountFormatter *f;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    f = [[NSByteCountFormatter alloc] init];
    f.countStyle = NSByteCountFormatterCountStyleFile;
    f.allowsNonnumericFormatting = NO;
  });
  return [f stringFromByteCount:(long long)size];
}

NSString *SZFormatSizeExact(uint64_t size)
{
  static NSNumberFormatter *f;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterDecimalStyle;
  });
  return [f stringFromNumber:@(size)];
}

NSString *SZFormatDate(NSDate *date)
{
  static NSDateFormatter *f;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    f = [[NSDateFormatter alloc] init];
    f.dateStyle = NSDateFormatterMediumStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    f.doesRelativeDateFormatting = YES;
  });
  return [f stringFromDate:date];
}

NSString *SZFormatDuration(double seconds)
{
  if (seconds < 0)
    seconds = 0;
  const unsigned long long s = (unsigned long long)seconds;
  return [NSString stringWithFormat:@"%02llu:%02llu:%02llu", s / 3600, (s / 60) % 60, s % 60];
}

NSString *SZFormatAttrib(uint32_t a)
{
  NSMutableString *s = [NSMutableString string];
  // Windows attributes
  if (a & 0x01) [s appendString:@"R"];
  if (a & 0x02) [s appendString:@"H"];
  if (a & 0x04) [s appendString:@"S"];
  if (a & 0x10) [s appendString:@"D"];
  if (a & 0x20) [s appendString:@"A"];
  if (a & 0x8000)
  {
    // POSIX mode in high 16 bits
    const uint32_t m = a >> 16;
    if (s.length)
      [s appendString:@" "];
    const char *types = "?pc?d?b?-?l?s???";
    [s appendFormat:@"%c", types[(m >> 12) & 15]];
    const char *rwx = "rwxrwxrwx";
    for (int i = 0; i < 9; i++)
      [s appendFormat:@"%c", (m & (1u << (8 - i))) ? rwx[i] : '-'];
  }
  return s;
}

NSImage *SZSymbol(NSString *name, CGFloat pointSize)
{
  NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  if (img && pointSize > 0)
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightRegular]];
  return img;
}

BOOL SZIsArchivePath(NSString *path)
{
  NSString *ext = [[path pathExtension] lowercaseString];
  if (ext.length == 0)
    return NO;
  // these files can be opened by 7-Zip, but usually user wants to run them
  static NSSet *excluded;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    excluded = [NSSet setWithArray:@[@"exe", @"dll", @"sys", @"so", @"dylib", @"o", @"obj", @"lib", @"a", @"msi", @"doc", @"xls", @"ppt",
        @"docx", @"xlsx", @"pptx", @"odt", @"ods", @"odp", @"epub", @"apk", @"ipa", @"jar", @"pages", @"numbers", @"key", @"mp4", @"mov", @"flv", @"swf", @"chm", @"img", @"pkg"]];
  });
  if ([excluded containsObject:ext])
    return NO;
  return NMacEngine::IsArchiveExtension(ext.UTF8String);
}

NSTextField *SZLabel(NSString *text)
{
  NSTextField *t = [NSTextField labelWithString:text];
  t.lineBreakMode = NSLineBreakByTruncatingMiddle;
  return t;
}

NSTextField *SZSecondaryLabel(NSString *text)
{
  NSTextField *t = SZLabel(text);
  t.textColor = [NSColor secondaryLabelColor];
  return t;
}

NSTextField *SZBoldLabel(NSString *text)
{
  NSTextField *t = SZLabel(text);
  t.font = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
  return t;
}

NSButton *SZCheckbox(NSString *title, BOOL on)
{
  NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
  b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
  return b;
}

NSPopUpButton *SZPopUp(NSArray<NSString *> *items)
{
  NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  [p addItemsWithTitles:items];
  return p;
}

NSButton *SZPushButton(NSString *title, id target, SEL action)
{
  NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
  b.bezelStyle = NSBezelStyleRounded;
  return b;
}

NSBox *SZSeparator(void)
{
  NSBox *b = [[NSBox alloc] init];
  b.boxType = NSBoxSeparator;
  return b;
}

NSGridView *SZFormGrid(NSArray<NSArray<NSView *> *> *rows)
{
  NSGridView *g = [NSGridView gridViewWithViews:rows];
  g.rowSpacing = 8;
  g.columnSpacing = 8;
  g.translatesAutoresizingMaskIntoConstraints = NO;
  if (g.numberOfColumns > 0)
    [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  for (NSInteger i = 0; i < g.numberOfRows; i++)
    [g rowAtIndex:i].yPlacement = NSGridCellPlacementCenter;
  SZHug(g);
  return g;
}

void SZHug(NSView *view)
{
  NSLayoutConstraint *w = [view.widthAnchor constraintEqualToConstant:0];
  NSLayoutConstraint *h = [view.heightAnchor constraintEqualToConstant:0];
  w.priority = 300;
  h.priority = 300;
  w.active = YES;
  h.active = YES;
}

void SZFitWindow(NSWindow *window, NSView *mainView)
{
  [window.contentView layoutSubtreeIfNeeded];
  const NSSize fit = mainView.fittingSize;
  if (fit.width > 10 && fit.height > 10)
    [window setContentSize:fit];
}

NSString *SZStripAmp(NSString *s)
{
  return [s stringByReplacingOccurrencesOfString:@"&" withString:@""];
}

void SZShowAlert(NSWindow *window, NSString *message, NSString *info, NSAlertStyle style)
{
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = message;
  if (info)
    a.informativeText = info;
  a.alertStyle = style;
  if (window && window.isVisible && !window.attachedSheet)
    [a beginSheetModalForWindow:window completionHandler:nil];
  else
    [a runModal];
}

NSString *SZTempFolder(void)
{
  static NSString *path;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"7-Zip.%d", [[NSProcessInfo processInfo] processIdentifier]]];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
  });
  return path;
}

NSString *SZCreateTempSubfolder(void)
{
  NSString *p = [SZTempFolder() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
  return p;
}
