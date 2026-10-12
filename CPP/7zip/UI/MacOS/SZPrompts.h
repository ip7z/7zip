// SZPrompts.h

#import <Cocoa/Cocoa.h>

#import "SZEngine.h"

NS_ASSUME_NONNULL_BEGIN

// If (window) is nil, the dialogs are shown as modal windows, otherwise as sheets.

void SZAskPassword(NSWindow * _Nullable window, NSString * _Nullable archiveName,
    void (^completion)(NSString * _Nullable password));

void SZAskOverwrite(NSWindow * _Nullable window, SZFileDesc *existing, SZFileDesc *newFile,
    void (^completion)(NMacEngine::EOverwriteAnswer answer));

void SZAskText(NSWindow * _Nullable window, NSString *title, NSString *label, NSString *defaultText,
    void (^completion)(NSString * _Nullable text));

void SZConfirm(NSWindow * _Nullable window, NSString *title, NSString *message, NSString *okTitle,
    BOOL destructive, void (^completion)(BOOL ok));

NS_ASSUME_NONNULL_END
