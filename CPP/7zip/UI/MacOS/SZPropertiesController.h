// SZPropertiesController.h

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// window that shows list of properties (name = value)
@interface SZPropertiesController : NSWindowController

// pairs: array of @[name, value]
+ (void)showProperties:(NSArray<NSArray<NSString *> *> *)pairs
                 title:(NSString *)title
                  icon:(nullable NSImage *)icon;

@end

NS_ASSUME_NONNULL_END
