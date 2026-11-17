#import "ChromiumBridge.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_devtools_message_observer_capi.h"
#include "include/capi/cef_image_capi.h"
#include "include/capi/cef_parser_capi.h"
#include "include/cef_application_mac.h"
#include "include/cef_api_hash.h"
#include <dlfcn.h>
#include <atomic>
#include <map>
#include <set>
#include <string>
#include <vector>

#define API(name) static decltype(&name) p_##name
API(cef_initialize); API(cef_shutdown); API(cef_do_message_loop_work);
API(cef_browser_host_create_browser_sync); API(cef_api_hash); API(cef_string_userfree_utf16_free);
API(cef_string_list_size); API(cef_string_list_value);
API(cef_request_context_get_global_context); API(cef_write_json);
static bool initialized = false, shuttingDown = false;
static NSTimer *pump;
static NSString *chromiumProfile;
static bool pumping = false;
static std::map<int, cef_browser_t *> browsers;
static void (^shutdownCompletion)(void);
// Page address for each favicon download in flight. CEF UI thread (the AppKit main thread) only.
static NSMutableDictionary<NSValue *, NSString *> *faviconPages;

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
    cef_registration_t *_devRegistration;
    NSMutableDictionary<NSNumber *, id> *_devCallbacks;
    int _devSequence;
    std::set<int> _devOutstanding;
    NSString *_url, *_title, *_pendingURL;
    BOOL _creating, _closed, _back, _forward, _loading, _automationCapture, _requestedHidden;
    NSString *_faviconURL;
}
@property(nonatomic, readwrite) BOOL openedInBackground;
- (void)emitState;
- (void)failDevTools:(NSString *)reason;
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

static cef_client_t *MakeChromeClient();

static bool IsChromeWindow(NSWindow *window) {
    if (!window) return false;
    while (window.sheetParent) window = window.sheetParent;
    for (auto entry : browsers) {
        auto host = entry.second->get_host(entry.second);
        bool matches = false;
        if (host->get_runtime_style(host) == CEF_RUNTIME_STYLE_CHROME) {
            NSView *view = (__bridge NSView *)host->get_window_handle(host);
            matches = view.window == window;
        }
        Release(host);
        if (matches) return true;
    }
    return false;
}

#include "BrowserPump.inc"

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
    LOAD(cef_string_list_size); LOAD(cef_string_list_value);
    LOAD(cef_request_context_get_global_context); LOAD(cef_write_json);
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
    chromiumProfile = profile;
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
    BOOL extensionsSmoke = smoke && [NSUserDefaults.standardUserDefaults volatileDomainForName:@"NeuraChromiumSmoke"][@"ExtensionsPort"] != nil;
    if (extensionsSmoke) settings.remote_debugging_port = [[NSUserDefaults.standardUserDefaults volatileDomainForName:@"NeuraChromiumSmoke"][@"ExtensionsPort"] intValue];
    char extensionDebug[] = "--enable-unsafe-extension-debugging";
    char *argv[] = {name, smoke ? mockKeychain : nullptr, extensionsSmoke ? extensionDebug : nullptr, nullptr};
    cef_main_args_t args = {extensionsSmoke ? 3 : (smoke ? 2 : 1), argv};
    auto app = new Handler<cef_app_t>(nil);
    app->api.get_browser_process_handler = [](cef_app_t *) -> cef_browser_process_handler_t * {
        auto handler = new Handler<cef_browser_process_handler_t>(nil);
        handler->api.on_schedule_message_pump_work = [](cef_browser_process_handler_t *, int64_t delay) {RequestPump(delay);};
        // Chrome-created tabs and windows must participate in our shutdown barrier.
        handler->api.get_default_client = [](cef_browser_process_handler_t *) {return MakeChromeClient();};
        return &handler->api;
    };
    if (!p_cef_initialize(&args, &settings, &app->api, nullptr)) return @"Chromiumを開始できませんでした。別のneuraOSで同じプロファイルを使用していないか確認してください。";
    initialized = true;
    StartPump();
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
NSString *NCChromiumProfileDirectory(void) {return chromiumProfile;}

#include "BrowserExtensions.inc"

// The enabled main-menu item bound to a key, searching submenus. `key` is the
// unshifted, lower-case character; an upper-case key equivalent implies Shift.
static NSMenuItem *MenuItemForKey(NSMenu *menu, NSString *key, NSEventModifierFlags flags) {
    if (!menu || !key.length) return nil;
    [menu update];
    const NSEventModifierFlags mask = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.hasSubmenu) {
            NSMenuItem *found = MenuItemForKey(item.submenu, key, flags);
            if (found) return found;
            continue;
        }
        NSString *equivalent = item.keyEquivalent;
        if (!equivalent.length || !item.enabled || item.hidden || !item.action) continue;
        NSEventModifierFlags wanted = item.keyEquivalentModifierMask & mask;
        if (![equivalent isEqualToString:equivalent.lowercaseString]) wanted |= NSEventModifierFlagShift;
        if (wanted == flags && [equivalent.lowercaseString isEqualToString:key]) return item;
    }
    return nil;
}

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
        h->api.on_auto_resize = [](cef_display_handler_t *s, cef_browser_t *browser, const cef_size_t *size) -> int {
            CallbackRef browserRef(browser); NCChromiumView *v = View(s);
            if (!v.onPreferredSize) return 0;
            v.onPreferredSize(size->width, size->height); return 1;
        };
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
        h->api.on_loading_progress_change = [](cef_display_handler_t *s, cef_browser_t *browser, double progress) {
            CallbackRef browserRef(browser);
            NCChromiumView *v = View(s);
            if (v.onProgress) v.onProgress(progress);
        };
        h->api.on_favicon_urlchange = [](cef_display_handler_t *s, cef_browser_t *browser, cef_string_list_t urls) {
            CallbackRef browserRef(browser);
            NCChromiumView *v = View(s); if (!v || v->_closed) return;
            cef_string_t first = {};
            NSString *url = urls && p_cef_string_list_size(urls) > 0 && p_cef_string_list_value(urls, 0, &first) ? String(&first) : @"";
            if (first.dtor) first.dtor(first.str);
            NSString *page = [v->_url copy] ?: @"";
            v->_faviconURL = url;
            if (!url.length) {if (v.onFavicon) v.onFavicon(nil, page); return;}
            // The page is remembered with the request: the tab may navigate before the icon arrives.
            auto done = new Handler<cef_download_image_callback_t>(v);
            if (!faviconPages) faviconPages = [NSMutableDictionary dictionary];
            faviconPages[[NSValue valueWithPointer:&done->api]] = page;
            done->api.on_download_image_finished = [](cef_download_image_callback_t *self, const cef_string_t *, int, cef_image_t *image) {
                CallbackRef imageRef(image);
                NCChromiumView *view = View(self);
                NSValue *key = [NSValue valueWithPointer:self];
                NSString *page = faviconPages[key];
                [faviconPages removeObjectForKey:key];
                if (!view || !image || !page) return;
                int width = 0, height = 0;
                auto value = image->get_as_png(image, 2, 1, &width, &height);
                if (!value) return;
                NSMutableData *data = [NSMutableData dataWithLength:value->get_size(value)];
                BOOL complete = data.length && value->get_data(value, data.mutableBytes, data.length, 0) == data.length;
                Release(value);
                if (complete && view.onFavicon) view.onFavicon(data, page);
            };
            auto host = browser->get_host(browser);
            NCString address(url);
            // is_favicon: no cookies are sent or stored for this request.
            host->download_image(host, &address.value, 1, 32, 0, &done->api);
            Release(host);
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
            [v failDevTools:@"browser_renderer_crashed"]; if (v) v->_devOutstanding.clear();
            if (v.onAutomationInvalidated) v.onAutomationInvalidated(@"browser_renderer_crashed");
            if (v.onError && !v->_closed) v.onError(@"ページの表示プロセスが終了しました。再読み込みしてください。");
        };
        // Cmd-click and middle-click ask for another tab without creating a popup.
        h->api.on_open_urlfrom_tab = [](cef_request_handler_t *s, cef_browser_t *browser, cef_frame_t *frame, const cef_string_t *url,
            cef_window_open_disposition_t disposition, int gesture) -> int {
            CallbackRef browserRef(browser); CallbackRef frameRef(frame);
            NCChromiumView *v = View(s);
            if (!gesture || shuttingDown || !v.onOpenTab) return 0;
            if (disposition != CEF_WOD_NEW_BACKGROUND_TAB && disposition != CEF_WOD_NEW_FOREGROUND_TAB && disposition != CEF_WOD_NEW_WINDOW) return 0;
            NSString *target = String(url); BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
            dispatch_async(dispatch_get_main_queue(), ^{if (v.onOpenTab) v.onOpenTab(target, background);});
            return 1;
        };
        return &h->api;
    };
    c->api.get_find_handler = [](cef_client_t *self) -> cef_find_handler_t * {
        auto h = new Handler<cef_find_handler_t>(View(self));
        h->api.on_find_result = [](cef_find_handler_t *s, cef_browser_t *browser, int, int count, const cef_rect_t *, int ordinal, int) {
            CallbackRef browserRef(browser);
            NCChromiumView *v = View(s);
            if (v.onFind) v.onFind(ordinal, count);
        };
        return &h->api;
    };
    c->api.get_keyboard_handler = [](cef_client_t *self) -> cef_keyboard_handler_t * {
        auto h = new Handler<cef_keyboard_handler_t>(View(self));
        // neuraOS routes its own shortcuts before a page sees them (KeyboardRouter). What
        // reaches here is offered to the remaining enabled menu items, such as Quit, Hide and
        // Settings; text editing keys and everything else are left to the page.
        h->api.on_pre_key_event = [](cef_keyboard_handler_t *, cef_browser_t *browser, const cef_key_event_t *event, cef_event_handle_t osEvent, int *) -> int {
            CallbackRef browserRef(browser);
            NSEvent *native = (__bridge NSEvent *)osEvent;
            if (event->type != KEYEVENT_RAWKEYDOWN || !(event->modifiers & EVENTFLAG_COMMAND_DOWN) || native.type != NSEventTypeKeyDown) return 0;
            NSEventModifierFlags flags = native.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
            NSString *key = ([native charactersByApplyingModifiers:0] ?: native.charactersIgnoringModifiers ?: @"").lowercaseString;
            if ((flags == NSEventModifierFlagCommand && [@[@"c", @"v", @"x", @"a", @"z"] containsObject:key]) ||
                (flags == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"z"])) return 0;
            NSMenuItem *item = MenuItemForKey(NSApp.mainMenu, key, flags);
            if (!item) return 0;
            // AppKit is still dispatching this event through the view hierarchy, and Chromium is
            // inside its own key handling. Run the menu action once both have unwound.
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMenu *menu = item.menu;
                NSInteger index = menu ? [menu indexOfItem:item] : -1;
                if (index >= 0 && item.enabled) [menu performActionForItemAtIndex:index];
            });
            return 1;
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
            const cef_string_t *, cef_window_open_disposition_t disposition, int, const cef_popup_features_t *, cef_window_info_t *info,
            cef_client_t **client, cef_browser_settings_t *, cef_dictionary_value_t **, int *) -> int {
            NCChromiumView *v = View(s);
            CallbackRef browserRef(browser); CallbackRef frameRef(frame);
            if (shuttingDown || !v.onPopup) return 1;
            NCChromiumView *child = [[NCChromiumView alloc] initWithFrame:v.bounds];
            child->_creating = YES;
            child.openedInBackground = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
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
            if (v) {[v failDevTools:@"browser_tab_closed"]; Release(v->_devRegistration); v->_devRegistration = nullptr; v->_devOutstanding.clear(); v->_browser = nullptr; if (!shuttingDown && v.onClosed) v.onClosed();}
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
    if (browser && self.onPreferredSize) {
        auto host = browser->get_host(browser);
        cef_size_t minimum = {400, 100}, maximum = {600, 600};
        host->set_auto_resize_enabled(host, 1, &minimum, &maximum); Release(host);
    }
    // Creation consumes the client reference; the returned browser is owned.
    Release(browser);
    _creating = NO;
    if (!_browser && self.onError) self.onError(@"Chromiumのタブを作成できませんでした。");
}
- (void)setHidden:(BOOL)hidden {
    _requestedHidden = hidden;
    if (hidden && _browser) {
        auto host = _browser->get_host(_browser); host->set_focus(host, 0); Release(host);
        id responder = self.window.firstResponder;
        if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:self]) [self.window makeFirstResponder:nil];
    }
    [super setHidden:_automationCapture ? NO : hidden];
}
- (void)beginAutomationCapture {_requestedHidden = self.hidden; _automationCapture = YES; [super setHidden:NO]; [self setNeedsDisplay:YES];}
- (void)endAutomationCapture {_automationCapture = NO; [self setHidden:_requestedHidden];}
- (void)setFrameSize:(NSSize)size {[super setFrameSize:size]; [self setNeedsLayout:YES];}
- (void)layout {[super layout]; for (NSView *child in self.subviews) {child.frame = self.bounds; child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;}}
- (void)emitState {if (self.onState) self.onState(_url ?: @"", _title ?: @"", _back, _forward, _loading);}
- (void)loadURL:(NSString *)url {
    _pendingURL = [url copy];
    if (_browser) {auto frame = _browser->get_main_frame(_browser); if (frame) {NCString value(url); frame->load_url(frame, &value.value); Release(frame);}}
    else if (self.window) [self createBrowser];
}
- (void)cancelDevTools {[self failDevTools:@"browser_cancelled"];}
- (void)failDevTools:(NSString *)reason {
    NSDictionary *callbacks = [_devCallbacks copy]; [_devCallbacks removeAllObjects];
    for (void (^callback)(NSString *, NSString *) in callbacks.allValues) callback(nil, reason);
}
- (void)devTools:(NSString *)method parameters:(NSString *)json completion:(void (^)(NSString *, NSString *))completion {
    NSAssert(NSThread.isMainThread, @"CEF DevTools must run on the AppKit thread");
    if (!_browser || _closed || shuttingDown) {completion(nil, @"browser_unavailable"); return;}
    // A timed-out/cancelled CDP call may still be in the renderer. Fail closed
    // until its result arrives (or that renderer closes), even after Swift unwinds.
    if (_devOutstanding.size() > _devCallbacks.count) {completion(nil, @"browser_uncertain"); return;}
    if (!_devCallbacks) _devCallbacks = [NSMutableDictionary dictionary];
    auto host = _browser->get_host(_browser);
    if (!_devRegistration) {
        auto observer = new Handler<cef_dev_tools_message_observer_t>(self);
        observer->api.on_dev_tools_method_result = [](cef_dev_tools_message_observer_t *s, cef_browser_t *browser, int messageId, int success, const void *result, size_t size) {
            CallbackRef browserRef(browser); NCChromiumView *v = View(s); if (!v) return;
            v->_devOutstanding.erase(messageId);
            void (^callback)(NSString *, NSString *) = v->_devCallbacks[@(messageId)];
            [v->_devCallbacks removeObjectForKey:@(messageId)];
            if (callback) callback(success ? ([[NSString alloc] initWithBytes:result length:size encoding:NSUTF8StringEncoding] ?: @"{}") : nil, success ? nil : @"browser_protocol_error");
        };
        observer->api.on_dev_tools_agent_detached = [](cef_dev_tools_message_observer_t *s, cef_browser_t *browser) {CallbackRef ref(browser); NCChromiumView *v = View(s); [v failDevTools:@"browser_renderer_crashed"]; if (v) v->_devOutstanding.clear();
            if (v.onAutomationInvalidated) v.onAutomationInvalidated(@"browser_renderer_crashed");};
        // CEF consumes the observer reference across its C API boundary.
        _devRegistration = host->add_dev_tools_message_observer(host, &observer->api);
    }
    NSNumber *requestId = @(++_devSequence);
    _devCallbacks[requestId] = [completion copy]; _devOutstanding.insert(requestId.intValue);
    id params = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"id":requestId, @"method":method, @"params":params ?: @{}} options:0 error:nil];
    BOOL sent = host->send_dev_tools_message(host, data.bytes, data.length); Release(host);
    if (!sent) {_devOutstanding.erase(requestId.intValue); [_devCallbacks removeObjectForKey:requestId]; completion(nil, @"browser_protocol_error"); return;}
    __weak NCChromiumView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NCChromiumView *v = weakSelf; if (!v) return;
        void (^callback)(NSString *, NSString *) = v->_devCallbacks[requestId]; [v->_devCallbacks removeObjectForKey:requestId];
        if (callback) callback(nil, @"browser_timeout");
    });
}
- (void)goBack {if (_browser) _browser->go_back(_browser);}
- (void)goForward {if (_browser) _browser->go_forward(_browser);}
- (void)reload {if (_browser) _browser->reload(_browser); else [self createBrowser];}
- (void)reloadIgnoringCache {if (_browser) _browser->reload_ignore_cache(_browser); else [self createBrowser];}
- (BOOL)hasBrowser {return _browser != nullptr;}
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next {
    if (!_browser) return;
    auto host = _browser->get_host(_browser);
    if (text.length) {NCString value(text); host->find(host, &value.value, forward, 0, next);}
    else host->stop_finding(host, 1);
    Release(host);
}
- (void)stopFinding {if (_browser) {auto host = _browser->get_host(_browser); host->stop_finding(host, 0); Release(host);}}
- (void)zoom:(NSInteger)delta {
    if (!_browser) return;
    auto host = _browser->get_host(_browser);
    // Chromium zoom levels are exponents of 1.2; keep within 25%...500%.
    double level = delta == 0 ? 0 : MAX(-7.6, MIN(8.8, host->get_zoom_level(host) + (delta > 0 ? 0.5 : -0.5)));
    host->set_zoom_level(host, level); Release(host);
}
- (void)showDevTools {
    if (!_browser || shuttingDown) return;
    auto host = _browser->get_host(_browser);
    cef_window_info_t info = {}; info.size = sizeof(info); info.bounds = {120, 120, 1000, 700};
    cef_browser_settings_t settings = {}; settings.size = sizeof(settings);
    // The DevTools window joins the shutdown barrier through the Chrome client.
    host->show_dev_tools(host, &info, MakeChromeClient(), &settings, nullptr);
    Release(host);
}
- (void)focusContent {
    if (!_browser || self.hidden) return;
    NSView *content = self.subviews.firstObject;
    if (content) [self.window makeFirstResponder:content];
    auto host = _browser->get_host(_browser); host->set_focus(host, 1); Release(host);
}
- (void)stop {if (_browser) _browser->stop_load(_browser);}
- (void)close {
    if (_closed) return; _closed = YES; [self cancelDevTools];
    if (_browser) CloseDownloads(_browser->get_identifier(_browser));
    // The view may deallocate before on_before_close (handlers hold it weakly).
    // Release our registration here; the later callback safely sees nullptr.
    Release(_devRegistration); _devRegistration = nullptr; _devOutstanding.clear();
    if (_browser) {auto host = _browser->get_host(_browser); host->close_browser(host, 1); Release(host);}
}
- (void)dealloc {[self close];}
@end

void NCShutdownChromium(void (^completion)(void)) {
    if (!initialized) {completion(); return;}
    shuttingDown = true; shutdownCompletion = [completion copy];
    // Chrome-style close may synchronously remove entries via on_before_close.
    // Retain a snapshot so callbacks cannot invalidate this traversal.
    std::vector<cef_browser_t *> closing;
    for (auto entry : browsers) {entry.second->base.add_ref(&entry.second->base); closing.push_back(entry.second);}
    for (auto browser : closing) {auto host = browser->get_host(browser); host->close_browser(host, 1); Release(host); Release(browser);}
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

#include "BrowserExtensionsSmoke.inc"
