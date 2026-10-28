#import "ChromiumBridge.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/cef_application_mac.h"
#include "include/cef_api_hash.h"
#include <dlfcn.h>
#include <atomic>
#include <map>
#include <string>

#define API(name) static decltype(&name) p_##name
API(cef_initialize); API(cef_shutdown); API(cef_do_message_loop_work);
API(cef_browser_host_create_browser_sync); API(cef_api_hash); API(cef_string_userfree_utf16_free);
static bool initialized = false, shuttingDown = false;
static NSTimer *pump;
static bool pumping = false;
static std::map<int, cef_browser_t *> browsers;
static void (^shutdownCompletion)(void);

@interface NCApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@property(nonatomic) BOOL terminatingChromium;
- (void)finishTermination:(id)sender;
@end
@implementation NCApplication
// Cocoa's NSTerminateLater enters a nested modal loop that can stall CEF.
// Keep the normal event loop alive while closing browsers, then terminate.
- (void)terminate:(id)sender {
    if (self.terminatingChromium) return;
    self.terminatingChromium = YES;
    NCShutdownChromium(^{[self finishTermination:sender];});
}
- (void)finishTermination:(id)sender {[super terminate:sender];}
- (BOOL)isHandlingSendEvent {return _handlingSendEvent;}
- (void)sendEvent:(NSEvent *)event {
    BOOL previous = _handlingSendEvent;
    _handlingSendEvent = YES;
    @try {[super sendEvent:event];} @finally {_handlingSendEvent = previous;}
}
@end
void NCPrepareApplication(void) {[NCApplication sharedApplication];}

static NSString *String(const cef_string_t *s) {
    return s && s->str ? [[NSString alloc] initWithCharacters:(const unichar *)s->str length:s->length] : @"";
}
// The NSString owns the backing copy for the duration of each synchronous CEF call.
struct NCString {
    std::u16string storage;
    cef_string_t value = {};
    explicit NCString(NSString *s) {
        storage.resize(s.length);
        [s getCharacters:(unichar *)storage.data() range:NSMakeRange(0, s.length)];
        value.str = (char16_t *)storage.data(); value.length = storage.size();
    }
};

template<class T> struct Handler {
    T api = {};
    std::atomic<int> refs{1};
    __weak NCChromiumView *view;
    explicit Handler(NCChromiumView *v): view(v) {
        api.base.size = sizeof(T);
        api.base.add_ref = [](cef_base_ref_counted_t *b) {++reinterpret_cast<Handler *>(b)->refs;};
        api.base.release = [](cef_base_ref_counted_t *b) -> int {auto h = reinterpret_cast<Handler *>(b); if (--h->refs == 0) {delete h; return 1;} return 0;};
        api.base.has_one_ref = [](cef_base_ref_counted_t *b) -> int {return reinterpret_cast<Handler *>(b)->refs == 1;};
        api.base.has_at_least_one_ref = [](cef_base_ref_counted_t *b) -> int {return reinterpret_cast<Handler *>(b)->refs > 0;};
    }
};
template<class T> static NCChromiumView *View(T *h) {return reinterpret_cast<Handler<T> *>(h)->view;}
template<class T> static void Release(T *p) {if(p) p->base.release(&p->base);}

// CEF C API transfers one reference for object callback parameters. `self`
// remains borrowed. RAII releases inputs even on early-return/error paths.
template<class T> struct CallbackRef {T *value; explicit CallbackRef(T *v): value(v) {} ~CallbackRef() {Release(value);}};

@interface NCChromiumView () {
@public
    cef_browser_t *_browser;
    NSString *_url, *_title, *_pendingURL;
    BOOL _creating, _closed, _back, _forward, _loading;
}
- (void)emitState;
- (void)createBrowser;
@end

#include "BrowserDownloads.inc"

static void CompleteShutdown() {
    if (!shuttingDown || !browsers.empty()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Dispatch blocks may themselves be drained from inside CEF's external pump.
        // Do not free that loop while cef_do_message_loop_work is still on the stack.
        if (!browsers.empty() || !initialized || pumping) return;
        [pump invalidate]; pump = nil;
        p_cef_shutdown(); initialized = false;
        if (shutdownCompletion) {auto completion = shutdownCompletion; shutdownCompletion = nil; completion();}
    });
}

BOOL NCChromiumUsesTestKeychain(void) {
    id path = [NSUserDefaults.standardUserDefaults volatileDomainForName:@"NeuraChromiumSmoke"][@"NeuraChromiumSmokeData"];
    return [path isKindOfClass:NSString.class] && [path length] > 0;
}

static NSString *StartChromiumImpl() {
    if (initialized) return nil;
    if (shuttingDown) return @"Chromiumは終了処理中です。";
    if (![NSApp isKindOfClass:NCApplication.class]) return @"Chromiumのアプリ初期化に失敗しました。";
    NSString *framework = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    void *library = dlopen([[framework stringByAppendingPathComponent:@"Chromium Embedded Framework"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
    if (!library) return @"Chromiumが同梱されていません。pnpm buildでアプリをビルドしてください。";
#define LOAD(name) p_##name = (decltype(p_##name))dlsym(library, #name); if (!p_##name) return @"ChromiumのAPIが見つかりません。"
    LOAD(cef_initialize); LOAD(cef_shutdown); LOAD(cef_do_message_loop_work);
    LOAD(cef_browser_host_create_browser_sync); LOAD(cef_api_hash); LOAD(cef_string_userfree_utf16_free);
#undef LOAD
    const char *apiHash = p_cef_api_hash(CEF_API_VERSION, 0);
    if (!apiHash || strcmp(apiHash, CEF_API_HASH_PLATFORM) != 0) return @"ChromiumのAPIバージョンが一致しません。";
    NSString *data = [NSUserDefaults.standardUserDefaults volatileDomainForName:@"NeuraChromiumSmoke"][@"NeuraChromiumSmokeData"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"NeuraDataDirectory"];
    if (!data.length) data = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/neuraOS"];
    NSString *profile = [[data stringByResolvingSymlinksInPath] stringByAppendingPathComponent:@"Chromium"];
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:&error]) return error.localizedDescription;
    char *canonical = realpath(profile.fileSystemRepresentation, nullptr);
    if (!canonical) return @"ブラウザ保存先を解決できませんでした。";
    profile = [NSString stringWithUTF8String:canonical]; free(canonical);
    cef_settings_t settings = {}; settings.size = sizeof(settings);
    NCString locale(@"ja"), languages(@"ja-JP,ja,en-US,en");
    settings.locale = locale.value;
    settings.accept_language_list = languages.value;
    NCString frameworkPath(framework), mainPath(NSBundle.mainBundle.bundlePath), root(profile), cache([profile stringByAppendingPathComponent:@"Default"]);
    settings.framework_dir_path = frameworkPath.value;
    settings.main_bundle_path = mainPath.value;
    NCString helper([NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"NeuraOS Helper.app/Contents/MacOS/NeuraOS Helper"]);
    settings.browser_subprocess_path = helper.value;
    settings.root_cache_path = root.value; settings.cache_path = cache.value;
    settings.persist_session_cookies = 1;
    // Keep Chromium's renderer/GPU sandbox enabled. Helpers initialize it before loading CEF.
    settings.no_sandbox = 0;
    settings.external_message_pump = 1;
    settings.log_severity = LOGSEVERITY_WARNING;
    NCString logPath([profile stringByAppendingPathComponent:@"chromium.log"]); settings.log_file = logPath.value;
    // Isolated smoke profiles must never read the user's real Keychain.
    // Chromium's test keychain avoids permission dialogs for disposable fixture data.
    BOOL smoke = NCChromiumUsesTestKeychain();
    char name[] = "NeuraOS", mockKeychain[] = "--use-mock-keychain";
    char *argv[] = {name, smoke ? mockKeychain : nullptr, nullptr}; cef_main_args_t args = {smoke ? 2 : 1, argv};
    if (!p_cef_initialize(&args, &settings, nullptr, nullptr)) return @"Chromiumを開始できませんでした。別のneuraOSで同じプロファイルを使用していないか確認してください。";
    initialized = true;
    // SwiftUI context menus can service default-mode turns while they track.
    // Run-loop mode alone does not protect their mouse-up/action dispatch.
    NSHashTable<NSMenu *> *trackingMenus = [NSHashTable weakObjectsHashTable];
    [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [trackingMenus addObject:note.object];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [trackingMenus removeObject:note.object];
    }];
    pump = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *) {
        // CEF's external pump drains AppKit events in the default run-loop mode.
        // Native modal windows/sheets must route their own mouse events; otherwise
        // the confirmation appears but its buttons never receive the clicks.
        if (!initialized || pumping) return;
        // Retry a deferred shutdown on a turn that does not enter CEF again.
        if (shuttingDown && browsers.empty()) {CompleteShutdown(); return;}
        if (NSApp.modalWindow || trackingMenus.count > 0) return;
        for (NSWindow *window in NSApp.windows) {
            if (window.attachedSheet || window.sheetParent) return;
        }
        pumping = true;
        @try {p_cef_do_message_loop_work();} @finally {pumping = false;}
    }];
    // Never enter Chromium's nested event pump while AppKit tracks a button,
    // context menu or drag. Common modes include NSEventTrackingRunLoopMode.
    // The timer resumes automatically when native tracking returns to default mode.
    [NSRunLoop.mainRunLoop addTimer:pump forMode:NSDefaultRunLoopMode];
    return nil;
}

static NSString *StartChromium() {
    static BOOL attempted = NO;
    static NSString *failure;
    if (initialized) return nil;
    // CEF initialization is single-shot, including a failed profile-lock attempt.
    // Opening another tab must not call cef_initialize a second time.
    if (attempted) return failure ?: @"Chromiumは終了しました。アプリを再起動してください。";
    attempted = YES;
    failure = StartChromiumImpl();
    return failure;
}
NSString *NCInitializeChromium(void) {return StartChromium();}

static cef_client_t *MakeClient(NCChromiumView *view);
static cef_window_info_t WindowInfo(NCChromiumView *view) {
    cef_window_info_t info = {}; info.size = sizeof(info);
    info.parent_view = (__bridge void *)view;
    info.bounds = {0, 0, (int)MAX(1, view.bounds.size.width), (int)MAX(1, view.bounds.size.height)};
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    return info;
}
static cef_client_t *MakeClient(NCChromiumView *view) {
    auto c = new Handler<cef_client_t>(view);
    c->api.get_download_handler = [](cef_client_t *self) -> cef_download_handler_t * {return MakeDownloadHandler(View(self));};
    c->api.get_display_handler = [](cef_client_t *self) -> cef_display_handler_t * {
        auto h = new Handler<cef_display_handler_t>(View(self));
        h->api.on_address_change = [](cef_display_handler_t *s, cef_browser_t *browser, cef_frame_t *frame, const cef_string_t *url) {
            CallbackRef browserRef(browser); CallbackRef frameRef(frame);
            if (!frame->is_main(frame)) return;
            NCChromiumView *v = View(s); if (!v) return;
            v->_url = String(url); [v emitState];
        };
        h->api.on_title_change = [](cef_display_handler_t *s, cef_browser_t *browser, const cef_string_t *title) {
            CallbackRef browserRef(browser);
            NCChromiumView *v = View(s); if (!v) return;
            v->_title = String(title); [v emitState];
        };
        return &h->api;
    };
    c->api.get_load_handler = [](cef_client_t *self) -> cef_load_handler_t * {
        auto h = new Handler<cef_load_handler_t>(View(self));
        h->api.on_loading_state_change = [](cef_load_handler_t *s, cef_browser_t *browser, int loading, int back, int forward) {
            CallbackRef browserRef(browser);
            NCChromiumView *v = View(s); if (!v) return;
            v->_loading = loading; v->_back = back; v->_forward = forward; [v emitState];
        };
        h->api.on_load_error = [](cef_load_handler_t *s, cef_browser_t *browser, cef_frame_t *frame, cef_errorcode_t code, const cef_string_t *message, const cef_string_t *) {
            CallbackRef browserRef(browser); CallbackRef frameRef(frame);
            NCChromiumView *v = View(s);
            if (code != ERR_ABORTED && frame->is_main(frame) && v.onError) v.onError(String(message));
        };
        return &h->api;
    };
    c->api.get_request_handler = [](cef_client_t *self) -> cef_request_handler_t * {
        auto h = new Handler<cef_request_handler_t>(View(self));
        h->api.on_render_process_terminated = [](cef_request_handler_t *s, cef_browser_t *browser, cef_termination_status_t, int, const cef_string_t *) {
            CallbackRef browserRef(browser);
            NCChromiumView *v = View(s);
            if (v.onError && !v->_closed) v.onError(@"ページの表示プロセスが終了しました。再読み込みしてください。");
        };
        return &h->api;
    };
    c->api.get_life_span_handler = [](cef_client_t *self) -> cef_life_span_handler_t * {
        auto h = new Handler<cef_life_span_handler_t>(View(self));
        h->api.on_after_created = [](cef_life_span_handler_t *s, cef_browser_t *browser) {
            browsers.emplace(browser->get_identifier(browser), browser); // Adopt the callback reference.
            NCChromiumView *v = View(s);
            if (v && !v->_closed && !shuttingDown) {
                v->_browser = browser; v->_creating = NO;
                auto host = browser->get_host(browser); host->set_accessibility_state(host, STATE_ENABLED); Release(host);
                [v setNeedsLayout:YES];
            }
            else {auto host = browser->get_host(browser); host->close_browser(host, 1); Release(host);}
        };
        h->api.on_before_popup = [](cef_life_span_handler_t *s, cef_browser_t *browser, cef_frame_t *frame, int, const cef_string_t *url,
            const cef_string_t *, cef_window_open_disposition_t, int, const cef_popup_features_t *, cef_window_info_t *info,
            cef_client_t **client, cef_browser_settings_t *, cef_dictionary_value_t **, int *) -> int {
            NCChromiumView *v = View(s);
            CallbackRef browserRef(browser); CallbackRef frameRef(frame);
            if (shuttingDown || !v.onPopup) return 1;
            NCChromiumView *child = [[NCChromiumView alloc] initWithFrame:v.bounds];
            child->_creating = YES;
            if (!v.onPopup(child, String(url))) return 1;
            child.hidden = YES;
            [v.window.contentView addSubview:child];
            auto childInfo = WindowInfo(child);
            info->parent_view = childInfo.parent_view; info->bounds = childInfo.bounds;
            info->runtime_style = childInfo.runtime_style; info->hidden = 0;
            info->windowless_rendering_enabled = 0;
            Release(*client); *client = MakeClient(child);
            return 0;
        };
        // Closing a browser tab must never close the containing neuraOS window.
        h->api.do_close = [](cef_life_span_handler_t *s, cef_browser_t *browser) -> int {
            CallbackRef browserRef(browser);
            NCChromiumView *v = View(s);
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    [v setHidden:YES];
                    [v.window makeFirstResponder:nil];
                    for (NSView *child in v.subviews.copy) [child removeFromSuperview];
                }
            });
            return 1;
        };
        h->api.on_before_close = [](cef_life_span_handler_t *s, cef_browser_t *browser) {
            NCChromiumView *v = View(s);
            CloseDownloads(browser->get_identifier(browser));
            if (v) {v->_browser = nullptr; if (!shuttingDown && v.onClosed) v.onClosed();}
            auto found = browsers.find(browser->get_identifier(browser));
            if (found != browsers.end()) {Release(found->second); browsers.erase(found);}
            Release(browser); CompleteShutdown();
        };
        return &h->api;
    };
    return &c->api;
}

@implementation NCChromiumView
- (instancetype)initWithFrame:(NSRect)frame {if ((self = [super initWithFrame:frame])) {_url = @""; _title = @""; _pendingURL = @"about:blank"; self.wantsLayer = YES;} return self;}
- (void)viewDidMoveToWindow {[super viewDidMoveToWindow]; if (self.window) [self createBrowser];}
- (void)createBrowser {
    if (_browser || _creating || _closed || shuttingDown) return;
    NSString *error = StartChromium();
    if (error) {if (self.onError) self.onError(error); return;}
    _creating = YES;
    auto info = WindowInfo(self); cef_browser_settings_t settings = {}; settings.size = sizeof(settings);
    auto client = MakeClient(self); NCString url(_pendingURL);
    auto browser = p_cef_browser_host_create_browser_sync(&info, client, &url.value, &settings, nullptr, nullptr);
    // Creation consumes the client reference; the returned browser is owned.
    Release(browser);
    _creating = NO;
    if (!_browser && self.onError) self.onError(@"Chromiumのタブを作成できませんでした。");
}
- (void)setHidden:(BOOL)hidden {
    if (hidden && _browser) {
        auto host = _browser->get_host(_browser); host->set_focus(host, 0); Release(host);
        id responder = self.window.firstResponder;
        if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:self]) [self.window makeFirstResponder:nil];
    }
    [super setHidden:hidden];
}
- (void)setFrameSize:(NSSize)size {[super setFrameSize:size]; [self setNeedsLayout:YES];}
- (void)layout {[super layout]; for (NSView *child in self.subviews) {child.frame = self.bounds; child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;}}
- (void)emitState {if (self.onState) self.onState(_url ?: @"", _title ?: @"", _back, _forward, _loading);}
- (void)loadURL:(NSString *)url {
    _pendingURL = [url copy];
    if (_browser) {auto frame = _browser->get_main_frame(_browser); if (frame) {NCString value(url); frame->load_url(frame, &value.value); Release(frame);}}
    else if (self.window) [self createBrowser];
}
- (void)goBack {if (_browser) _browser->go_back(_browser);}
- (void)goForward {if (_browser) _browser->go_forward(_browser);}
- (void)reload {if (_browser) _browser->reload(_browser); else [self createBrowser];}
- (void)stop {if (_browser) _browser->stop_load(_browser);}
- (void)close {
    if (_closed) return; _closed = YES;
    if (_browser) CloseDownloads(_browser->get_identifier(_browser));
    if (_browser) {auto host = _browser->get_host(_browser); host->close_browser(host, 1); Release(host);}
}
- (void)dealloc {[self close];}
@end

void NCShutdownChromium(void (^completion)(void)) {
    if (!initialized) {completion(); return;}
    shuttingDown = true; shutdownCompletion = [completion copy];
    for (auto entry : browsers) {auto browser = entry.second; auto host = browser->get_host(browser); host->close_browser(host, 1); Release(host);}
    CompleteShutdown();
}

int NCRunChromiumSmoke(NSString *url, NSString *dataDirectory) {
    // This entry point never starts the daemon or reads the normal browser profile.
    if (![@[@"127.0.0.1", @"localhost"] containsObject:[NSURL URLWithString:url].host] || !dataDirectory.length) return 2;
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"NeuraChromiumSmokeData": dataDirectory} forName:@"NeuraChromiumSmoke"];
    NSString *startupError = StartChromium();
    if (startupError) {fprintf(stderr, "%s\n", startupError.UTF8String); return 1;}
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 640) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NCChromiumView *view = [[NCChromiumView alloc] initWithFrame:window.contentView.bounds];
    __block int result = 1;
    __block BOOL finished = NO, mainLoaded = NO, popupLoaded = NO;
    __block NCChromiumView *popup;
    void (^finish)(int) = ^(int code) {
        if (finished) return; finished = YES; result = code;
        [view close]; [popup close];
        NCShutdownChromium(^{[NSApp stop:nil]; [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];});
    };
    view.onClosed = ^{result = 1; fprintf(stderr, "Shutdown must not remove saved workspace tabs\n");};
    view.onError = ^(NSString *error) {fprintf(stderr, "Chromium smoke error: %s\n", error.UTF8String); dispatch_async(dispatch_get_main_queue(), ^{finish(1);});};
    __block int navigationStage = 0;
    __weak NCChromiumView *weakView = view;
    view.onState = ^(NSString *, NSString *title, BOOL back, BOOL forward, BOOL loading) {
        if (loading) return;
        NCChromiumView *current = weakView;
        if ([title isEqualToString:@"neura-second"] && (navigationStage == 1 || navigationStage == 3)) {
            if (!back) {dispatch_async(dispatch_get_main_queue(), ^{finish(1);}); return;}
            navigationStage++;
            dispatch_async(dispatch_get_main_queue(), ^{[current goBack];});
        } else if ([title hasPrefix:@"neura-main:Chrome/"]) {
            if (navigationStage == 0) {
                navigationStage = 1;
                NSString *second = [[NSURL URLWithString:@"/second" relativeToURL:[NSURL URLWithString:url]] absoluteString];
                dispatch_async(dispatch_get_main_queue(), ^{[current loadURL:second];});
            } else if (navigationStage == 2) {
                if (!forward) {dispatch_async(dispatch_get_main_queue(), ^{finish(1);}); return;}
                navigationStage = 3;
                dispatch_async(dispatch_get_main_queue(), ^{[current goForward];});
            } else if (navigationStage == 4) {
                navigationStage = 5; mainLoaded = YES;
                fprintf(stdout, "%s navigation-ok\n", title.UTF8String); fflush(stdout);
                // Exercise the real CEF input path against the fixed local fixture.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                    if (!current->_browser) return;
                    [current setHidden:YES]; [current setHidden:NO];
                    auto host = current->_browser->get_host(current->_browser); host->set_focus(host, 1);
                    cef_mouse_event_t event = {}; event.x = 50; event.y = 30;
                    host->send_mouse_click_event(host, &event, MBT_LEFT, 0, 1);
                    host->send_mouse_click_event(host, &event, MBT_LEFT, 1, 1); Release(host);
                });
            }
            if (mainLoaded && popupLoaded) dispatch_async(dispatch_get_main_queue(), ^{finish(0);});
        }
    };
    view.onPopup = ^BOOL(NCChromiumView *child, NSString *) {
        popup = child;
        child.onError = weakView.onError;
        child.onClosed = weakView.onClosed;
        child.onState = ^(NSString *, NSString *title, BOOL, BOOL, BOOL loading) {
            if (!loading && [title isEqualToString:@"neura-popup:opener-ok"]) {
                popupLoaded = YES;
                fprintf(stdout, "%s\n", title.UTF8String); fflush(stdout);
                if (mainLoaded) dispatch_async(dispatch_get_main_queue(), ^{finish(0);});
            }
        };
        return YES;
    };
    @autoreleasepool {
        [view loadURL:url];
        [window.contentView addSubview:view];
        [window makeKeyAndOrderFront:nil];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{finish(1);});
    [NSApp run];
    view.onState = nil; view.onError = nil; view.onPopup = nil;
    popup.onState = nil; popup.onError = nil;
    [window orderOut:nil];
    return result;
}

#include "BrowserDownloadSmoke.inc"
#include "BrowserDownloadRegression.inc"
