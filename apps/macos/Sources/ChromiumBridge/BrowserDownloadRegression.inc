// Exercises the real callback handlers with owned CEF C-API stubs, without
// initializing Chromium, reading a user profile, or presenting a save panel.
BOOL NCVerifyDownloadTerminalStates(void) {
    static int terminalKind, continuations, cancellations;
    static uint32_t identifier;
    static NSString *retriedPath;
    continuations = 0; cancellations = 0;
    auto browser = []() {
        auto h = new Handler<cef_browser_t>(nil);
        h->api.get_identifier = [](cef_browser_t *) -> int {return -108;};
        return &h->api;
    };
    auto item = []() {
        auto h = new Handler<cef_download_item_t>(nil);
        h->api.is_valid = [](cef_download_item_t *) -> int {return 1;};
        h->api.get_id = [](cef_download_item_t *) -> uint32_t {return identifier;};
        h->api.get_received_bytes = [](cef_download_item_t *) -> int64_t {return 0;};
        h->api.get_total_bytes = [](cef_download_item_t *) -> int64_t {return 100;};
        h->api.get_full_path = [](cef_download_item_t *) -> cef_string_userfree_t {return nullptr;};
        h->api.is_interrupted = [](cef_download_item_t *) -> int {return terminalKind == 0;};
        h->api.is_complete = [](cef_download_item_t *) -> int {return terminalKind == 1;};
        h->api.is_canceled = [](cef_download_item_t *) -> int {return terminalKind == 2;};
        h->api.is_in_progress = [](cef_download_item_t *) -> int {return terminalKind == 3;};
        h->api.get_interrupt_reason = [](cef_download_item_t *) {return CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_FAILED;};
        return &h->api;
    };
    BOOL passed = YES;
    auto handler = MakeDownloadHandler(nil);
    for (int kind = 0; kind < 3; kind++) {
        identifier = UINT32_MAX - kind;
        terminalKind = kind;
        NCDownload *download = Download(identifier, -108);
        auto original = new Handler<cef_before_download_callback_t>(nil);
        original->api.cont = [](cef_before_download_callback_t *, const cef_string_t *, int) {continuations++;};
        original->api.base.add_ref(&original->api.base); // Test holds a reference after terminal cleanup.
        download->_before = &original->api;
        download->_selectionGeneration = 1;
        handler->on_download_updated(handler, browser(), item(), &((new Handler<cef_download_item_callback_t>(nil))->api));
        NSString *terminal = download.status;
        passed &= DownloadTerminal(download) && download->_before == nullptr && original->refs == 1;

        // Updated may precede BeforeDownload. A late before must release its
        // incoming reference without queuing a panel for the terminal record.
        auto late = new Handler<cef_before_download_callback_t>(nil);
        late->api.base.add_ref(&late->api.base);
        handler->on_before_download(handler, browser(), item(), nullptr, &late->api);
        passed &= late->refs == 1 && download->_before == nullptr && download->_panel == nil;
        // A delayed Save response must not revive the record or execute cont.
        SelectDownloadDestination(download, &original->api, 1, nil, [NSURL fileURLWithPath:@"/tmp/never-written"]);
        passed &= [download.status isEqualToString:terminal] && continuations == 0;
        // Late progress notifications also cannot replace a terminal state.
        terminalKind = 3;
        handler->on_download_updated(handler, browser(), item(), &((new Handler<cef_download_item_callback_t>(nil))->api));
        passed &= [download.status isEqualToString:terminal];
        Release(&late->api); Release(&original->api);
        [downloadHistory removeObject:download];
    }
    // Save can consume BeforeDownload before CEF supplies any control callback.
    // A user cancel in that gap must reach the first late update's control.
    identifier = UINT32_MAX - 3; terminalKind = 3;
    NCDownload *pending = Download(identifier, -108);
    auto before = new Handler<cef_before_download_callback_t>(nil);
    before->api.cont = [](cef_before_download_callback_t *, const cef_string_t *, int) {continuations++;};
    before->api.base.add_ref(&before->api.base);
    pending->_before = &before->api; pending->_selectionGeneration = 1;
    NCChromiumView *owner = [[NCChromiumView alloc] initWithFrame:NSZeroRect];
    SelectDownloadDestination(pending, &before->api, 1, owner, [NSURL fileURLWithPath:@"/tmp/never-written"]);
    passed &= continuations == 1 && pending->_before == nullptr && pending->_control == nullptr;
    // Chromium retries may repeat BeforeDownload while the same ID is running.
    // Keep the approved destination even if its current path is an intermediate file.
    pending.path = @"/tmp/intermediate.crdownload";
    auto retry = new Handler<cef_before_download_callback_t>(nil);
    retry->api.cont = [](cef_before_download_callback_t *, const cef_string_t *path, int showDialog) {
        continuations++; retriedPath = showDialog ? @"unexpected-dialog" : String(path);
    };
    retry->api.base.add_ref(&retry->api.base);
    handler->on_before_download(handler, browser(), item(), nullptr, &retry->api);
    passed &= continuations == 2 && [retriedPath isEqualToString:@"/tmp/never-written"] && retry->refs == 1;
    passed &= pending->_before == nullptr && pending->_panel == nil && pending->_selectionGeneration == 1;
    Release(&retry->api);
    [pending cancel];
    auto lateControl = new Handler<cef_download_item_callback_t>(nil);
    lateControl->api.cancel = [](cef_download_item_callback_t *) {cancellations++;};
    lateControl->api.base.add_ref(&lateControl->api.base);
    handler->on_download_updated(handler, browser(), item(), &lateControl->api);
    passed &= cancellations == 1 && [pending.status isEqualToString:@"canceled"] && lateControl->refs == 1;
    passed &= pending->_before == nullptr && pending->_control == nullptr;
    Release(&before->api); Release(&lateControl->api);
    [downloadHistory removeObject:pending];
    Release(handler);
    return passed;
}
