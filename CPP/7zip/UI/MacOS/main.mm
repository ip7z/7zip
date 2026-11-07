// main.mm

#import <Cocoa/Cocoa.h>

#import "AppDelegate.h"

int main(int argc, const char *argv[])
{
  @autoreleasepool
  {
    NSApplication *app = [NSApplication sharedApplication];
    static AppDelegate *delegate;
    delegate = [[AppDelegate alloc] init];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
