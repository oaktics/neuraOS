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

NSString *NCOpenExtensionWindow(NSString *url) {
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
