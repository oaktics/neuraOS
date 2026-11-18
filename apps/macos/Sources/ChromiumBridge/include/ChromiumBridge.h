#import "BrowserDownloads.h"
#import "BrowserExtensionActions.h"
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *NCChromiumInvalidationReason(BOOL closeRequested, BOOL cefReadyToClose);
// Called before SwiftUI creates NSApplication. No Chromium work happens in tests.
FOUNDATION_EXPORT void NCPrepareApplication(void);
FOUNDATION_EXPORT NSString * _Nullable NCInitializeChromium(void);
FOUNDATION_EXPORT NSString * _Nullable NCChromiumProfileDirectory(void);
// Opens a full Chrome-style window in the same profile as embedded tabs.
FOUNDATION_EXPORT NSString * _Nullable NCOpenExtensionWindow(NSString *url);
FOUNDATION_EXPORT void NCShutdownChromium(void (^completion)(void));
@interface NCChromiumView : NSView
// Chrome Views surface: a native child window with Chrome-owned tab/action context.
// Keeps the Chrome toolbar and extension permissions associated with this page.
- (instancetype)initWithFrame:(NSRect)frame chromeTab:(BOOL)chromeTab;
@property(nonatomic, readonly) BOOL chromeTab;
// Chrome tabs carry one neuraOS button at the end of Chromium's toolbar row.
// Its menu is built when the button is pressed; the symbol is an SF Symbol name.
@property(nonatomic, copy, nullable) NSMenu * _Nullable (^onToolbarMenu)(void);
@property(nonatomic, copy, nullable) NSString *toolbarSymbol;
@property(nonatomic, copy, nullable) void (^onState)(NSString *url, NSString *title, BOOL back, BOOL forward, BOOL loading);
@property(nonatomic, copy, nullable) void (^onError)(NSString *message);
@property(nonatomic, copy, nullable) BOOL (^onPopup)(NCChromiumView *view, NSString *url);
@property(nonatomic, copy, nullable) void (^onClosed)(void);
@property(nonatomic, copy, nullable) void (^onAutomationInvalidated)(NSString *reason);
// Optional intrinsic sizing for extension document popovers; unset for normal tabs.
@property(nonatomic, copy, nullable) void (^onPreferredSize)(NSInteger width, NSInteger height);
// Overall page load progress, 0...1.
@property(nonatomic, copy, nullable) void (^onProgress)(double progress);
// PNG bytes of the icon of `pageURL`, or nil when that page has none.
@property(nonatomic, copy, nullable) void (^onFavicon)(NSData * _Nullable png, NSString *pageURL);
// Result of the active find session: current match (1-based) and total.
@property(nonatomic, copy, nullable) void (^onFind)(NSInteger ordinal, NSInteger count);
// A user gesture asked for another tab without a popup (for example cmd-click).
@property(nonatomic, copy, nullable) void (^onOpenTab)(NSString *url, BOOL background);
// Set on a popup's view before onPopup runs: the opener asked for a background tab.
@property(nonatomic, readonly) BOOL openedInBackground;
// False until Chromium has created the page for this view.
@property(nonatomic, readonly) BOOL hasBrowser;
// Internal DevTools transport; never exposed as a generic MCP method.
- (void)devTools:(NSString *)method parameters:(NSString *)json completion:(void (^)(NSString * _Nullable result, NSString * _Nullable error))completion;
- (void)cancelDevTools;
- (void)beginAutomationCapture;
- (void)endAutomationCapture;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next;
- (void)stopFinding;
// delta > 0 zooms in, < 0 zooms out, 0 restores the default size.
- (void)zoom:(NSInteger)delta;
- (void)showDevTools;
// Give keyboard focus back to the page.
- (void)focusContent;
- (void)stop;
- (void)close;
@end
// Exact hosted Chrome window only; extension popups/DevTools retain their own keys.
FOUNDATION_EXPORT NCChromiumView * _Nullable NCChromiumOwnerForWindow(NSWindow * _Nullable window);
NS_ASSUME_NONNULL_END
// Packaged, isolated integration check. Requires a loopback fixture URL.
FOUNDATION_EXPORT int NCRunChromiumSmoke(NSString * _Nonnull url, NSString * _Nonnull dataDirectory);

FOUNDATION_EXPORT int NCRunDownloadSmoke(NSString * _Nonnull url, NSString * _Nonnull dataDirectory, NSView * _Nonnull accessory);

// True only for the process-local isolated smoke profile, never persisted preferences.
FOUNDATION_EXPORT BOOL NCChromiumUsesTestKeychain(void);

// Optional UI fixture adapter; called only after the isolated-bundle guard.
@protocol NCExtensionsSmokeToolbarProviding
- (NSView * _Nullable)toolbarForBrowser:(NCChromiumView * _Nonnull)browser URL:(NSString * _Nonnull)url;
@end

FOUNDATION_EXPORT int NCRunExtensionsSmoke(NSString * _Nonnull url, NSString * _Nonnull dataDirectory, int port, NSView * _Nullable accessory);
