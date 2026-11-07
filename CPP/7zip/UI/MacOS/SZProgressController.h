// SZProgressController.h

#import <Cocoa/Cocoa.h>

#import "SZEngine.h"

NS_ASSUME_NONNULL_BEGIN

/*
  Progress window. It's similar to ProgressDialog2 in Windows version.
  The operation is executed in worker thread.
  If there are errors, the window shows the list of messages.
*/

@interface SZProgressController : NSWindowController <SZOperationPrompts>

// parent : if it's not nil, the progress window is shown as sheet.
// completion is called in main thread after the window was closed.
+ (void)runOperation:(SZOperation *)op
              parent:(nullable NSWindow *)parent
                work:(void (^)(SZOperation *op))work
          completion:(nullable void (^)(SZOperation *op))completion;

@end

NSString *SZOperationName(NMacEngine::EOperation op);

NS_ASSUME_NONNULL_END
