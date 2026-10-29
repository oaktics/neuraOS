#include <sys/resource.h>
// Disposable test bundles only. Production never exposes a debugging endpoint.
int NCRunExtensionsSmoke(NSString *url, NSString *dataDirectory, int port, NSView *accessory) {
    if (![NSBundle.mainBundle.bundleIdentifier hasPrefix:@"com.neuraos.extensions-test"] ||
        ![[NSURL URLWithString:url].host isEqualToString:@"127.0.0.1"] || !dataDirectory.length || port < 1024 || port > 65535) return 2;
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"NeuraChromiumSmokeData":dataDirectory, @"ExtensionsPort":@(port)} forName:@"NeuraChromiumSmoke"];
    pumpFixed10Test = [NSFileManager.defaultManager fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"pump-fixed10"]];
    BOOL probe = [NSFileManager.defaultManager fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"pump-probe"]];
    NSString *error = NCOpenExtensionWindow(@"chrome://extensions/");
    if (error) {fprintf(stderr, "%s\n", error.UTF8String); return 1;}
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 850, 600) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Extensions smoke — embedded Alloy";
    NCChromiumView *view = [[NCChromiumView alloc] initWithFrame:window.contentView.bounds];
    @autoreleasepool {
        [view loadURL:url]; [window.contentView addSubview:view]; [window makeKeyAndOrderFront:nil];
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp activateIgnoringOtherApps:YES];
    NSWindow *setupWindow;
    if ([NSFileManager.defaultManager fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"setup-ui"]] && accessory) {
        setupWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 180, 570, 590) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        setupWindow.title = @"1Password setup — isolated test";
        setupWindow.contentView = accessory; [setupWindow makeKeyAndOrderFront:nil];
    }
    __block BOOL stopping = NO;
    __block NSDictionary *baseline;
    NSDate *started = [NSDate date];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:900];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *) {
        if (stopping) return;
        NSString *modal = [dataDirectory stringByAppendingPathComponent:@"native-sheet"];
        if ([NSFileManager.defaultManager fileExistsAtPath:modal]) {
            [NSFileManager.defaultManager removeItemAtPath:modal error:nil];
            [window makeKeyAndOrderFront:nil];
            NSAlert *alert = [NSAlert new]; alert.messageText = @"Native modal regression";
            [alert addButtonWithTitle:@"Cancel test"];
            [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
                [@"native-sheet-dismissed" writeToFile:[dataDirectory stringByAppendingPathComponent:@"modal-evidence.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }];
        }
        double elapsed = -started.timeIntervalSinceNow;
        if (probe && elapsed >= 2) {
            struct rusage usage; getrusage(RUSAGE_SELF, &usage);
            double cpu = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
            if (!baseline) baseline = @{@"time":@(elapsed), @"cpu":@(cpu), @"wakes":@(pumpWakes), @"works":@(pumpWorks), @"blocked":@(pumpBlocked), @"reentries":@(pumpReentries)};
            else if (elapsed >= 12) {
                NSDictionary *result = @{@"mode":pumpFixed10Test ? @"fixed10" : @"adaptive", @"seconds":@(elapsed - [baseline[@"time"] doubleValue]), @"cpuSeconds":@(cpu - [baseline[@"cpu"] doubleValue]), @"timerWakeups":@(pumpWakes - [baseline[@"wakes"] unsignedLongLongValue]), @"workCalls":@(pumpWorks - [baseline[@"works"] unsignedLongLongValue]), @"blocked":@(pumpBlocked - [baseline[@"blocked"] unsignedLongLongValue]), @"reentries":@(pumpReentries - [baseline[@"reentries"] unsignedLongLongValue])};
                [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[dataDirectory stringByAppendingPathComponent:@"pump-evidence.json"] atomically:YES];
                [@"stop" writeToFile:[dataDirectory stringByAppendingPathComponent:@"stop"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        if ([NSFileManager.defaultManager fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"stop"]] || deadline.timeIntervalSinceNow < 0) {
            stopping = YES;
            NCShutdownChromium(^{[NSApp stop:nil]; [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];});
        }
    }];
    [NSApp run]; [timer invalidate]; [window orderOut:nil];
    return 0;
}
