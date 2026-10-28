#import "BrowserDownloads.h"
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
// Called before SwiftUI creates NSApplication. No Chromium work happens in tests.
FOUNDATION_EXPORT void NCPrepareApplication(void);
FOUNDATION_EXPORT NSString * _Nullable NCInitializeChromium(void);
FOUNDATION_EXPORT void NCShutdownChromium(void (^completion)(void));
@interface NCChromiumView : NSView
@property(nonatomic, copy, nullable) void (^onState)(NSString *url, NSString *title, BOOL back, BOOL forward, BOOL loading);
@property(nonatomic, copy, nullable) void (^onError)(NSString *message);
@property(nonatomic, copy, nullable) BOOL (^onPopup)(NCChromiumView *view, NSString *url);
@property(nonatomic, copy, nullable) void (^onClosed)(void);
@property(nonatomic, copy, nullable) void (^onAutomationInvalidated)(NSString *reason);
// Internal DevTools transport; never exposed as a generic MCP method.
- (void)devTools:(NSString *)method parameters:(NSString *)json completion:(void (^)(NSString * _Nullable result, NSString * _Nullable error))completion;
- (void)cancelDevTools;
- (void)beginAutomationCapture;
- (void)endAutomationCapture;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)close;
@end
NS_ASSUME_NONNULL_END
// Packaged, isolated integration check. Requires a loopback fixture URL.
FOUNDATION_EXPORT int NCRunChromiumSmoke(NSString * _Nonnull url, NSString * _Nonnull dataDirectory);

FOUNDATION_EXPORT int NCRunDownloadSmoke(NSString * _Nonnull url, NSString * _Nonnull dataDirectory, NSView * _Nonnull accessory);

// True only for the process-local isolated smoke profile, never persisted preferences.
FOUNDATION_EXPORT BOOL NCChromiumUsesTestKeychain(void);
