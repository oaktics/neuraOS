// Isolated packaged integration test: real CEF download callbacks and NSSavePanel.
int NCRunDownloadSmoke(NSString *url, NSString *dataDirectory, NSView *accessory) {
    if (![@[@"127.0.0.1", @"localhost"] containsObject:[NSURL URLWithString:url].host] || !dataDirectory.length) return 2;
    NSString *destination = [dataDirectory stringByAppendingPathComponent:@"downloads"];
    // Refuse to reuse a directory: the fixture must never replace user files.
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] || ![NSFileManager.defaultManager createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil]) return 2;
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"NeuraChromiumSmokeData": dataDirectory} forName:@"NeuraChromiumSmoke"];
    if (StartChromium()) return 1;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 640) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSTitlebarAccessoryViewController *toolbar = [NSTitlebarAccessoryViewController new];
    accessory.frame = NSMakeRect(0, 0, 160, 32); toolbar.view = accessory; toolbar.layoutAttribute = NSLayoutAttributeRight;
    [window addTitlebarAccessoryViewController:toolbar];
    NCChromiumView *view = [[NCChromiumView alloc] initWithFrame:window.contentView.bounds];
    __block int stage = 0, result = 1, clickedStage = -1;
    __block BOOL finished = NO;
    __block NSTimer *timer;
    void (^finish)(int) = ^(int code) {
        if (finished) return; finished = YES; result = code; [timer invalidate];
        NSMutableArray *report = [NSMutableArray array];
        for (NCDownload *item in NCBrowserDownloads()) [report addObject:@{@"status":item.status, @"path":item.path, @"received":@(item.received), @"detail":item.detail}];
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[dataDirectory stringByAppendingPathComponent:@"download-report.json"] atomically:YES];
        [view close];
        NCShutdownChromium(^{[NSApp stop:nil]; [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];});
    };
    NSArray *routes = @[@"complete", @"cancel", @"failed", @"dismiss"];
    BOOL manual = getenv("NEURA_DOWNLOAD_SMOKE_MANUAL") != nullptr;
    downloadSmokeChoose = ^(NSSavePanel *panel, NSWindow *owner, void (^selected)(NSURL *)) {
        NSURL *target = [NSURL fileURLWithPath:[destination stringByAppendingPathComponent:[routes[stage] stringByAppendingString:@".bin"]]];
        if (!manual) {selected(stage == 3 ? nil : target); return;}
        panel.directoryURL = [NSURL fileURLWithPath:destination];
        panel.nameFieldStringValue = target.lastPathComponent;
        fprintf(stdout, "SAVE PANEL: %s (use Save; dismiss stage uses Cancel)\n", [routes[stage] UTF8String]); fflush(stdout);
        [panel beginSheetModalForWindow:owner completionHandler:^(NSModalResponse response) {
            selected(response == NSModalResponseOK ? panel.URL : nil);
        }];
    };
    void (^navigate)(void) = ^{[view loadURL:[url stringByAppendingFormat:@"/page/%@", routes[stage]]];};
    __weak NCChromiumView *weakDownloadView = view;
    view.onState = ^(NSString *, NSString *title, BOOL, BOOL, BOOL loading) {
        if (loading || finished || stage >= routes.count || clickedStage == stage || ![title isEqualToString:[@"download-fixture-" stringByAppendingString:routes[stage]]]) return;
        clickedStage = stage;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            NCChromiumView *current = weakDownloadView;
            if (!current || !current->_browser || finished) return;
            auto host = current->_browser->get_host(current->_browser);
            cef_mouse_event_t event = {}; event.x = 50; event.y = 30;
            host->send_mouse_click_event(host, &event, MBT_LEFT, 0, 1);
            host->send_mouse_click_event(host, &event, MBT_LEFT, 1, 1); Release(host);
        });
    };
    view.onError = ^(NSString *error) {fprintf(stderr, "Download fixture: %s\n", error.UTF8String);};
    @autoreleasepool {
        navigate();
        [window.contentView addSubview:view]; [window makeKeyAndOrderFront:nil];
    }
    timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *) {
        NCDownload *item = NCBrowserDownloads().firstObject;
        if (!item || finished || NCBrowserDownloads().count != stage + 1) return;
        if (stage == 1 && [item.status isEqualToString:@"running"] && item.received > 0) [item cancel];
        NSString *expected = stage == 0 ? @"complete" : stage == 2 ? @"failed" : @"canceled";
        if ([item.status isEqualToString:expected]) {
            fprintf(stdout, "download %s: %s (%lld bytes)\n", [routes[stage] UTF8String], item.status.UTF8String, item.received); fflush(stdout);
            stage++;
            if (stage == 4) {
                [timer invalidate];
                if (manual) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{finish(0);});
                else finish(0);
                return;
            }
            // Avoid observing the previous terminal item before the next callback.
            [timer setFireDate:[NSDate dateWithTimeIntervalSinceNow:2]];
            navigate();
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (manual ? 600 : 60) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{finish(1);});
    [NSApp run]; downloadSmokeChoose = nil; view.onState = nil; [window orderOut:nil]; return result;
}
