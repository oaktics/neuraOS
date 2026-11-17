NS_ASSUME_NONNULL_BEGIN

// Chrome owns these top-level windows, including extension permissions, toolbar,
// popups and downloads. Embedded Alloy tabs keep their existing client callbacks.
static cef_client_t *MakeChromeClient() {
    auto client = new Handler<cef_client_t>(nil);
    client->api.get_life_span_handler = [](cef_client_t *) -> cef_life_span_handler_t * {
        auto handler = new Handler<cef_life_span_handler_t>(nil);
        handler->api.on_after_created = [](cef_life_span_handler_t *, cef_browser_t *browser) {
            browsers.emplace(browser->get_identifier(browser), browser);
            auto host = browser->get_host(browser); host->set_accessibility_state(host, STATE_ENABLED); Release(host);
            if (shuttingDown) {auto host = browser->get_host(browser); host->close_browser(host, 1); Release(host);}
        };
        handler->api.on_before_close = [](cef_life_span_handler_t *, cef_browser_t *browser) {
            auto found = browsers.find(browser->get_identifier(browser));
            if (found != browsers.end()) {Release(found->second); browsers.erase(found);}
            Release(browser); CompleteShutdown();
        };
        return &handler->api;
    };
    return &client->api;
}

NSString * _Nullable NCOpenExtensionWindow(NSString *url) {
    NSCAssert(NSThread.isMainThread, @"CEF windows must open on the AppKit thread");
    NSURL *parsed = [NSURL URLWithString:url];
    BOOL web = [@[@"http", @"https"] containsObject:parsed.scheme.lowercaseString] && parsed.host.length && !parsed.user && !parsed.password;
    if (!web && ![url isEqualToString:@"chrome://extensions/"] && ![url isEqualToString:@"about:blank"]) return @"このURLは拡張対応ウィンドウで開けません。";
    NSString *error = StartChromium();
    if (error) return error;
    cef_window_info_t info = {}; info.size = sizeof(info);
    info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    info.bounds = {80, 80, 1100, 780};
    cef_browser_settings_t settings = {}; settings.size = sizeof(settings);
    NCString address(url);
    // No parent_view: CEF forces Alloy for embedded macOS views. A null request
    // context selects the global, persistent profile used by NCChromiumView.
    auto browser = p_cef_browser_host_create_browser_sync(&info, MakeChromeClient(), &address.value, &settings, nullptr, nullptr);
    if (!browser) return @"拡張対応ウィンドウを作成できませんでした。";
    Release(browser);
    return nil;
}

@interface NCExtensionAction ()
@property(nonatomic, readwrite) NSString *identifier;
@property(nonatomic, readwrite) NSString *title;
@property(nonatomic, readwrite, nullable) NSString *popupURL;
@property(nonatomic, readwrite, nullable) NSImage *icon;
@end
@implementation NCExtensionAction
@end

static NSDictionary *ExtensionJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static NSString * _Nullable ExtensionString(id _Nullable value) {return [value isKindOfClass:NSString.class] ? value : nil;}
// Manifests may be unpacked in an external directory. Resource paths must stay
// within that installation, including after symlink resolution.
static NSString * _Nullable ExtensionResource(NSString *root, id _Nullable value) {
    NSString *relative = ExtensionString(value);
    if (!relative.length || relative.isAbsolutePath) return nil;
    char *rootPath = realpath(root.fileSystemRepresentation, nullptr);
    if (!rootPath) return nil;
    NSString *base = [NSString stringWithUTF8String:rootPath]; free(rootPath);
    NSString *candidate = [base stringByAppendingPathComponent:relative].stringByStandardizingPath;
    char *resolved = realpath(candidate.fileSystemRepresentation, nullptr);
    if (!resolved) return nil;
    NSString *path = [NSString stringWithUTF8String:resolved]; free(resolved);
    return [path hasPrefix:[base stringByAppendingString:@"/"]] ? path : nil;
}
static NSString *ExtensionLocalized(NSString *value, NSDictionary *manifest, NSString *root) {
    if (value.length < 8 || ![value hasPrefix:@"__MSG_"] || ![value hasSuffix:@"__"]) return value;
    NSString *key = [[value substringWithRange:NSMakeRange(6, value.length - 8)] lowercaseString];
    NSMutableArray *locales = [NSMutableArray array];
    for (NSString *language in NSLocale.preferredLanguages) {
        NSString *locale = [language stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        [locales addObject:locale]; [locales addObject:[locale componentsSeparatedByString:@"_"].firstObject];
    }
    if (ExtensionString(manifest[@"default_locale"])) [locales addObject:manifest[@"default_locale"]];
    for (NSString *locale in locales) {
        NSString *path = ExtensionResource(root, [NSString stringWithFormat:@"_locales/%@/messages.json", locale]);
        NSDictionary *messages = path ? ExtensionJSON(path) : @{};
        for (NSString *name in messages) {
            if ([name.lowercaseString isEqualToString:key] && [messages[name] isKindOfClass:NSDictionary.class]) {
                NSString *message = ExtensionString(messages[name][@"message"]);
                if (message.length) return message;
            }
        }
    }
    return value;
}
NSArray<NCExtensionAction *> *NCReadExtensionActions(NSDictionary *settings, NSString *profile) {
    NSMutableArray *result = [NSMutableArray array];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet];
    for (NSString *identifier in settings) {
        if (![identifier isKindOfClass:NSString.class] || identifier.length != 32 || [identifier rangeOfCharacterFromSet:invalid].location != NSNotFound) continue;
        NSDictionary *entry = settings[identifier];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        // Chromium 156 removed the old state field. Disabled extensions carry
        // a nonempty disable_reasons list; retain support for older profiles.
        if (entry[@"state"] && ![entry[@"state"] isKindOfClass:NSNumber.class]) continue;
        id reasons = entry[@"disable_reasons"];
        BOOL enabled = [entry[@"state"] isKindOfClass:NSNumber.class] ? [entry[@"state"] intValue] == 1 :
            (!reasons || ([reasons isKindOfClass:NSArray.class] && [reasons count] == 0));
        if (!enabled || (reasons && (![reasons isKindOfClass:NSArray.class] || [reasons count] != 0))) continue;
        BOOL blocked = NO;
        for (NSString *key in @[@"blacklist", @"blacklist_state", @"omaha_blocklist_state", @"extension_telemetry_service_blocklist_state"]) {
            id state = entry[key];
            if (state && (![state isKindOfClass:NSNumber.class] || [state integerValue] != 0)) blocked = YES;
        }
        if (blocked) continue;
        NSString *root = ExtensionString(entry[@"path"]);
        if (!root.length) continue;
        if (!root.isAbsolutePath) root = ExtensionResource([profile stringByAppendingPathComponent:@"Extensions"], root);
        if (!root) continue;
        NSString *manifestPath = ExtensionResource(root, @"manifest.json");
        if (!manifestPath) continue;
        NSDictionary *manifest = ExtensionJSON(manifestPath);
        if (![manifest[@"manifest_version"] isKindOfClass:NSNumber.class] || [manifest[@"manifest_version"] intValue] != 3) continue;
        NSDictionary *action = manifest[@"action"] ?: @{};
        if (![action isKindOfClass:NSDictionary.class]) continue;
        NCExtensionAction *item = [NCExtensionAction new]; item.identifier = identifier;
        item.title = ExtensionLocalized(ExtensionString(action[@"default_title"]) ?: ExtensionString(manifest[@"name"]) ?: identifier, manifest, root);
        NSString *popup = ExtensionString(action[@"default_popup"]);
        NSURLComponents *popupParts = popup ? [NSURLComponents componentsWithString:popup] : nil;
        if (popup.length && !popupParts.scheme && !popupParts.host && ExtensionResource(root, popupParts.path)) {
            NSURL *base = [NSURL URLWithString:[NSString stringWithFormat:@"chrome-extension://%@/", identifier]];
            NSURL *url = [NSURL URLWithString:popup relativeToURL:base].absoluteURL;
            if ([url.scheme isEqualToString:@"chrome-extension"] && [url.host isEqualToString:identifier] && !url.user && !url.password) item.popupURL = url.absoluteString;
        }
        id icons = action[@"default_icon"] ?: manifest[@"icons"];
        NSString *icon;
        if ([icons isKindOfClass:NSString.class]) icon = icons;
        else if ([icons isKindOfClass:NSDictionary.class]) {
            NSArray *sizes = [[icons allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {return [@([a integerValue]) compare:@([b integerValue])];}];
            for (NSString *size in sizes) {icon = ExtensionString(icons[size]); if (size.integerValue >= 32) break;}
        }
        NSString *iconPath = ExtensionResource(root, icon);
        if (iconPath) item.icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        [result addObject:item];
    }
    return [result sortedArrayUsingComparator:^NSComparisonResult(NCExtensionAction *a, NCExtensionAction *b) {return [a.title localizedCaseInsensitiveCompare:b.title];}];
}
NSArray<NCExtensionAction *> *NCExtensionActions(void) {
    NSCAssert(NSThread.isMainThread, @"CEF preferences require the AppKit thread");
    if (!initialized || shuttingDown) return @[];
    auto context = p_cef_request_context_get_global_context();
    NCString name(@"extensions.settings");
    auto value = context->base.get_preference(&context->base, &name.value);
    auto json = value ? p_cef_write_json(value, JSON_WRITER_DEFAULT) : nullptr;
    NSData *data = json ? [String(json) dataUsingEncoding:NSUTF8StringEncoding] : nil;
    id settings = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (json) p_cef_string_userfree_utf16_free(json);
    // cef_write_json consumes the value reference across the C API boundary.
    Release(&context->base);
    return [settings isKindOfClass:NSDictionary.class] ? NCReadExtensionActions(settings, [chromiumProfile stringByAppendingPathComponent:@"Default"]) : @[];
}

@interface NCExtensionPopover ()
@property(nonatomic, nullable) NSPopover *popover;
@property(nonatomic, nullable) NCChromiumView *content;
@property(nonatomic, weak, nullable) NCChromiumView *source;
@end
@implementation NCExtensionPopover
- (NSString * _Nullable)showExtension:(NSString *)identifier fromView:(NSView *)anchor source:(NCChromiumView *)source {
    [self close];
    if (!anchor.window || !source.hasBrowser || shuttingDown) return @"ブラウザの準備ができていません。";
    NCExtensionAction *action = nil;
    for (NCExtensionAction *candidate in NCExtensionActions()) if ([candidate.identifier isEqualToString:identifier]) {action = candidate; break;}
    if (!action) return @"拡張機能が無効化または削除されています。";
    if (!action.popupURL) return @"この拡張機能は拡張対応ウィンドウのツールバーから実行してください。";
    self.source = source;
    self.content = [[NCChromiumView alloc] initWithFrame:NSMakeRect(0, 0, 400, 500)];
    // Reuse the normal CEF lifecycle/download client and global request context.
    // No synthetic Chrome action, injected bindings or permission grants.
    self.content.onPopup = source.onPopup;
    self.content.onOpenTab = source.onOpenTab;
    self.content.onError = source.onError;
    __weak NCExtensionPopover *weakSelf = self;
    self.content.onClosed = ^{[weakSelf close];};
    self.content.onPreferredSize = ^(NSInteger width, NSInteger height) {
        NCExtensionPopover *owner = weakSelf;
        owner.popover.contentSize = NSMakeSize(MAX(400, MIN(600, width)), MAX(100, MIN(600, height)) + 50);
    };
    [self.content loadURL:action.popupURL];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 550)];
    self.content.frame = NSMakeRect(0, 50, 400, 500);
    self.content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:self.content];
    NSTextField *note = [NSTextField labelWithString:@"このポップアップは現在のタブに紐づいていません"];
    note.font = [NSFont systemFontOfSize:11]; note.textColor = NSColor.secondaryLabelColor;
    note.autoresizingMask = NSViewWidthSizable;
    note.frame = NSMakeRect(10, 28, 380, 16); [container addSubview:note];
    NSButton *fallback = [NSButton buttonWithTitle:@"このページを拡張対応ウィンドウで開く" target:self action:@selector(openFallback:)];
    fallback.autoresizingMask = NSViewWidthSizable;
    fallback.frame = NSMakeRect(8, 2, 384, 26); [container addSubview:fallback];
    NSViewController *controller = [NSViewController new]; controller.view = container;
    self.popover = [NSPopover new]; self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.delegate = self; self.popover.contentViewController = controller;
    self.popover.contentSize = container.frame.size;
    [self.popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
    [self.content focusContent];
    return nil;
}
- (void)openFallback:(id)sender {
    NCChromiumView *source = self.source;
    if (!source) {[self close]; return;}
    NSString *url = source->_url;
    [self close];
    if (url.length) {NSString *error = NCOpenExtensionWindow(url); if (error && source.onError) source.onError(error);}
}
- (void)popoverDidClose:(NSNotification *)notification {[self close];}
- (void)close {
    NSPopover *popover = self.popover; self.popover = nil; popover.delegate = nil;
    [self.content close]; self.content = nil;
    [popover close];
}
- (void)dealloc {[self.content close]; self.popover.delegate = nil; [self.popover close];}
@end

NS_ASSUME_NONNULL_END
