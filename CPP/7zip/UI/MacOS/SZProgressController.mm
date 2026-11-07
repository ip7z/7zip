// SZProgressController.mm

#import "SZProgressController.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZPrompts.h"
#import "SZUtils.h"

using namespace NMacEngine;

static NSMutableSet *g_RunningControllers;

NSString *SZOperationName(EOperation op)
{
  switch (op)
  {
    case kOp_Scanning:   return SZLang(kLang_Scanning, @"Scanning...");
    case kOp_Opening:    return SZLang(kLang_Opening, @"Opening...");
    case kOp_Extracting: return SZLang(kLang_Extracting, @"Extracting");
    case kOp_Testing:    return SZLang(kLang_Testing, @"Testing");
    case kOp_Skipping:   return SZLang(kLang_OpSkipping, @"Skipping");
    case kOp_Add:        return SZLang(kLang_OpAdd, @"Adding");
    case kOp_Update:     return SZLang(kLang_OpUpdate, @"Updating");
    case kOp_Analyze:    return SZLang(kLang_OpAnalyze, @"Analyzing");
    case kOp_Replicate:  return SZLang(kLang_OpReplicate, @"Replicating");
    case kOp_Repack:     return SZLang(kLang_OpRepack, @"Repacking");
    case kOp_Skip:       return SZLang(kLang_OpSkipping, @"Skipping");
    case kOp_Delete:     return SZLang(kLang_OpDelete, @"Deleting");
    case kOp_Header:     return SZLang(kLang_OpHeader, @"Header creating");
    case kOp_Moving:     return SZLang(kLang_Moving, @"Moving");
    case kOp_Removing:   return SZLang(kLang_Removing, @"Removing");
    default:             return @"";
  }
}


@interface SZProgressController ()
@property (strong) SZOperation *op;
@property (weak) NSWindow *parentWindow;
@property (copy) void (^completion)(SZOperation *);
@end


@implementation SZProgressController
{
  NSTimer *_timer;
  BOOL _finished;
  BOOL _shown;

  NSTextField *_statusLabel;
  NSTextField *_fileLabel;
  NSTextField *_elapsedValue;
  NSTextField *_remainingValue;
  NSTextField *_filesValue;
  NSTextField *_ratioValue;
  NSTextField *_totalValue;
  NSTextField *_speedValue;
  NSTextField *_processedValue;
  NSTextField *_packedValue;
  NSTextField *_errorsLabel;
  NSTextField *_errorsValue;
  NSProgressIndicator *_bar;
  NSButton *_pauseButton;
  NSButton *_cancelButton;
  NSScrollView *_messagesScroll;
  NSTextView *_messagesView;
  NSStackView *_mainStack;
}

+ (void)runOperation:(SZOperation *)op
              parent:(NSWindow *)parent
                work:(void (^)(SZOperation *op))work
          completion:(void (^)(SZOperation *op))completion
{
  SZProgressController *c = [[SZProgressController alloc] initWithOperation:op parent:parent];
  c.completion = completion;
  if (!g_RunningControllers)
    g_RunningControllers = [NSMutableSet set];
  [g_RunningControllers addObject:c];
  [c startWithWork:work];
}

static NSTextField *ValueLabel(void)
{
  NSTextField *t = SZLabel(@"");
  t.font = [NSFont monospacedDigitSystemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightRegular];
  t.alignment = NSTextAlignmentRight;
  return t;
}

static NSTextField *NameLabel(uint32_t langID, NSString *s)
{
  NSTextField *t = SZSecondaryLabel(SZStripAmp(SZLang(langID, s)));
  return t;
}

- (instancetype)initWithOperation:(SZOperation *)op parent:(NSWindow *)parent
{
  NSPanel *w = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 240)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable
      backing:NSBackingStoreBuffered defer:YES];
  w.releasedWhenClosed = NO;
  w.hidesOnDeactivate = NO;
  w.floatingPanel = NO;
  self = [super initWithWindow:w];
  if (!self)
    return nil;
  _op = op;
  _parentWindow = parent;
  op.prompts = self;
  [self buildUI];
  w.title = op.title;
  return self;
}

- (void)buildUI
{
  _statusLabel = SZBoldLabel(_op.title);
  _fileLabel = SZSecondaryLabel(@"");
  _fileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [_fileLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  _elapsedValue = ValueLabel();
  _remainingValue = ValueLabel();
  _filesValue = ValueLabel();
  _ratioValue = ValueLabel();
  _totalValue = ValueLabel();
  _speedValue = ValueLabel();
  _processedValue = ValueLabel();
  _packedValue = ValueLabel();
  _errorsValue = ValueLabel();
  _errorsValue.textColor = [NSColor systemRedColor];
  _errorsLabel = NameLabel(kLang_ProgressErrors, @"Errors:");

  NSGridView *grid = [NSGridView gridViewWithViews:@[
    @[NameLabel(kLang_ProgressElapsed, @"Elapsed time:"), _elapsedValue, NameLabel(kLang_ProgressTotal, @"Total size:"), _totalValue],
    @[NameLabel(kLang_ProgressRemaining, @"Remaining time:"), _remainingValue, NameLabel(kLang_ProgressSpeed, @"Speed:"), _speedValue],
    @[NameLabel(kLang_ProgressFiles, @"Files:"), _filesValue, NameLabel(kLang_ProgressProcessed, @"Processed:"), _processedValue],
    @[NameLabel(kLang_ProgressRatio, @"Compression ratio:"), _ratioValue, NameLabel(kLang_ProgressPacked, @"Packed Size:"), _packedValue],
    @[_errorsLabel, _errorsValue, [NSGridCell emptyContentView], [NSGridCell emptyContentView]],
  ]];
  grid.rowSpacing = 4;
  grid.columnSpacing = 8;
  [grid columnAtIndex:1].width = 110;
  [grid columnAtIndex:3].width = 110;
  [grid columnAtIndex:2].leadingPadding = 24;
  [grid rowAtIndex:4].hidden = YES;
  SZHug(grid);

  _bar = [[NSProgressIndicator alloc] init];
  _bar.style = NSProgressIndicatorStyleBar;
  _bar.indeterminate = YES;
  _bar.minValue = 0;
  _bar.maxValue = 100;
  [_bar startAnimation:nil];

  _pauseButton = SZPushButton(SZStripAmp(SZLang(kLang_Pause, @"Pause")), self, @selector(pauseClicked:));
  _cancelButton = SZPushButton(SZLang(kLang_Cancel, @"Cancel"), self, @selector(cancelClicked:));
  _cancelButton.keyEquivalent = @"\033";
  NSView *spacer = [[NSView alloc] init];
  [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *buttons = [NSStackView stackViewWithViews:@[spacer, _pauseButton, _cancelButton]];

  _messagesView = [[NSTextView alloc] init];
  _messagesView.editable = NO;
  _messagesView.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
  _messagesView.textContainerInset = NSMakeSize(4, 4);
  _messagesScroll = [[NSScrollView alloc] init];
  _messagesScroll.documentView = _messagesView;
  _messagesScroll.hasVerticalScroller = YES;
  _messagesScroll.borderType = NSBezelBorder;
  _messagesView.autoresizingMask = NSViewWidthSizable;
  _messagesView.minSize = NSMakeSize(0, 0);
  _messagesView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
  _messagesView.verticallyResizable = YES;
  _messagesView.textContainer.widthTracksTextView = YES;
  [_messagesScroll.heightAnchor constraintEqualToConstant:160].active = YES;
  _messagesScroll.hidden = YES;

  _mainStack = [NSStackView stackViewWithViews:@[_statusLabel, _fileLabel, grid, _bar, _messagesScroll, buttons]];
  _mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _mainStack.alignment = NSLayoutAttributeLeading;
  _mainStack.spacing = 8;
  [_mainStack setCustomSpacing:2 afterView:_statusLabel];
  [_mainStack setCustomSpacing:14 afterView:_fileLabel];
  [_mainStack setCustomSpacing:14 afterView:grid];
  _mainStack.edgeInsets = NSEdgeInsetsMake(18, 20, 18, 20);
  _mainStack.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *content = self.window.contentView;
  [content addSubview:_mainStack];
  [NSLayoutConstraint activateConstraints:@[
    [_mainStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [_mainStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [_mainStack.topAnchor constraintEqualToAnchor:content.topAnchor],
    [_mainStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [_bar.widthAnchor constraintEqualToAnchor:_mainStack.widthAnchor constant:-40],
    [buttons.widthAnchor constraintEqualToAnchor:_mainStack.widthAnchor constant:-40],
    [_messagesScroll.widthAnchor constraintEqualToAnchor:_mainStack.widthAnchor constant:-40],
    [_fileLabel.widthAnchor constraintLessThanOrEqualToAnchor:_mainStack.widthAnchor constant:-40],
    [content.widthAnchor constraintEqualToConstant:520],
  ]];
  SZFitWindow(self.window, _mainStack);
}

- (void)startWithWork:(void (^)(SZOperation *op))work
{
  _timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
  [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSModalPanelRunLoopMode];

  // the window is shown with small delay, so it doesn't blink for fast operations
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (!self->_finished)
      [self showWindowNow];
  });

  SZOperation *op = _op;
  NSThread *thread = [[NSThread alloc] initWithBlock:^{
    @autoreleasepool {
      work(op);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self operationFinished];
    });
  }];
  thread.stackSize = 16 << 20;
  thread.qualityOfService = NSQualityOfServiceUserInitiated;
  [thread start];
}

- (void)showWindowNow
{
  if (_shown)
    return;
  _shown = YES;
  [self updateUI];
  NSWindow *parent = _parentWindow;
  if (parent && parent.isVisible && !parent.attachedSheet)
    [parent beginSheet:self.window completionHandler:nil];
  else
  {
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
  }
}

- (void)closeWindow
{
  if (!_shown)
    return;
  if (self.window.sheetParent)
    [self.window.sheetParent endSheet:self.window];
  else
    [self.window orderOut:nil];
}

- (void)timerFired:(NSTimer *)t
{
  [self updateUI];
}

- (void)updateUI
{
  const SZProgressSnapshot s = [_op snapshot];
  const double elapsed = [_op elapsedTime];

  NSString *opName = SZOperationName(s.Op);
  if (opName.length == 0)
    opName = _op.title;
  _statusLabel.stringValue = _op.paused ? SZLang(kLang_Paused, @"Paused") : opName;
  _fileLabel.stringValue = [_op currentFileName] ?: @"";

  _elapsedValue.stringValue = SZFormatDuration(elapsed);
  _totalValue.stringValue = s.Total ? SZFormatSize(s.Total) : @"";
  _processedValue.stringValue = SZFormatSize(s.Completed);

  if (elapsed > 0.5 && s.Completed > 0)
  {
    const double speed = (double)s.Completed / elapsed;
    _speedValue.stringValue = [NSString stringWithFormat:@"%@/s", SZFormatSize((uint64_t)speed)];
    if (s.Total > s.Completed && speed > 0)
      _remainingValue.stringValue = SZFormatDuration((double)(s.Total - s.Completed) / speed);
    else
      _remainingValue.stringValue = SZFormatDuration(0);
  }
  else
  {
    _speedValue.stringValue = @"";
    _remainingValue.stringValue = @"";
  }

  if (s.NumFilesTotal)
    _filesValue.stringValue = [NSString stringWithFormat:@"%llu / %llu", s.NumFiles, s.NumFilesTotal];
  else
    _filesValue.stringValue = [NSString stringWithFormat:@"%llu", s.NumFiles];

  if (s.RatioDefined && s.InSize)
  {
    _ratioValue.stringValue = [NSString stringWithFormat:@"%llu%%", s.OutSize * 100 / s.InSize];
    _packedValue.stringValue = SZFormatSize(s.OutSize);
  }
  else
  {
    _ratioValue.stringValue = @"";
    _packedValue.stringValue = @"";
  }

  if (s.NumErrors)
  {
    _errorsValue.stringValue = [NSString stringWithFormat:@"%llu", s.NumErrors];
    [(NSGridView *)_mainStack.arrangedSubviews[2] rowAtIndex:4].hidden = NO;
  }

  double percent = -1;
  if (s.Total)
    percent = (double)(s.Completed > s.Total ? s.Total : s.Completed) * 100.0 / (double)s.Total;
  if (percent >= 0)
  {
    if (_bar.indeterminate)
    {
      [_bar stopAnimation:nil];
      _bar.indeterminate = NO;
    }
    _bar.doubleValue = percent;
    self.window.title = [NSString stringWithFormat:@"%d%% %@ %@", (int)percent, _op.title, _op.subtitle];
  }
  else
    self.window.title = [NSString stringWithFormat:@"%@ %@", _op.title, _op.subtitle];
}

- (void)pauseClicked:(id)sender
{
  _op.paused = !_op.paused;
  _pauseButton.title = _op.paused ?
      SZStripAmp(SZLang(kLang_Continue, @"Continue")) :
      SZStripAmp(SZLang(kLang_Pause, @"Pause"));
  [self updateUI];
}

- (void)cancelClicked:(id)sender
{
  if (_finished)
  {
    [self finishAndClose];
    return;
  }
  _op.cancelled = YES;
  _op.paused = NO;
  _cancelButton.enabled = NO;
}

- (void)operationFinished
{
  _finished = YES;
  [_timer invalidate];
  _timer = nil;

  const CResult r = _op.result;
  NSArray<NSString *> *messages = [_op messages];
  const BOOL aborted = (r.HResult == (int32_t)0x80004004) || _op.cancelled;

  if (messages.count == 0 || aborted || _op.quiet)
  {
    [self finishAndClose];
    return;
  }

  // show messages in the window, like Windows version does
  [self showWindowNow];
  [self updateUI];
  [_bar stopAnimation:nil];
  _bar.indeterminate = NO;
  _bar.doubleValue = 100;
  _statusLabel.stringValue = [_op hasErrors] ?
      [NSString stringWithFormat:@"%@ %llu", SZStripAmp(SZLang(kLang_ProgressErrors, @"Errors:")), [_op snapshot].NumErrors] :
      _op.title;
  _fileLabel.stringValue = @"";
  _pauseButton.hidden = YES;
  _cancelButton.title = SZStripAmp(SZLang(kLang_Close, @"Close"));
  _cancelButton.keyEquivalent = @"\r";
  _cancelButton.enabled = YES;
  _messagesView.string = [messages componentsJoinedByString:@"\n\n"];
  _messagesScroll.hidden = NO;
  SZFitWindow(self.window, _mainStack);
  NSBeep();
}

- (void)finishAndClose
{
  [self closeWindow];
  void (^c)(SZOperation *) = _completion;
  _completion = nil;
  SZOperation *op = _op;
  [g_RunningControllers removeObject:self];
  if (c)
    c(op);
}

// ---------- SZOperationPrompts ----------

- (void)operation:(SZOperation *)op askPasswordWithCompletion:(void (^)(NSString *))completion
{
  [self showWindowNow];
  [op beginUserWait];
  SZAskPassword(self.window, op.subtitle, ^(NSString *password) {
    [op endUserWait];
    completion(password);
  });
}

- (void)operation:(SZOperation *)op askOverwriteExisting:(SZFileDesc *)existing
    withNew:(SZFileDesc *)newFile completion:(void (^)(EOverwriteAnswer))completion
{
  [self showWindowNow];
  [op beginUserWait];
  SZAskOverwrite(self.window, existing, newFile, ^(EOverwriteAnswer a) {
    [op endUserWait];
    completion(a);
  });
}

@end
