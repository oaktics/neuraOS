// Standalone integration harness; isolated profile, local fixture server and mock keychain.
// Compiled by tab-context-probe.mjs, never linked into the normal application.
#import "../../../apps/macos/Sources/ChromiumBridge/ChromiumBridge.mm"

@interface NCTabContextProbe : NSObject
@property(nonatomic) NSWindow *window;
@property(nonatomic) NSArray<NCChromiumView *> *tabs;
@property(nonatomic) NSInteger selected;
- (void)select:(NSButton *)sender;
@end
@implementation NCTabContextProbe
- (void)select:(NSButton *)sender {
    self.selected = sender.tag;
    for (NSInteger i = 0; i < self.tabs.count; ++i) self.tabs[i].hidden = i != self.selected;
    [self.tabs[self.selected] focusContent];
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4 || ![NSBundle.mainBundle.bundleIdentifier hasPrefix:@"com.neuraos.extensions-test.tab-context."]) return 2;
        NSString *data = [NSString stringWithUTF8String:argv[1]], *base = [NSString stringWithUTF8String:argv[2]];
        int port = atoi(argv[3]);
        if (![[NSURL URLWithString:base].host isEqualToString:@"127.0.0.1"] || port < 1024 || port > 65535) return 2;
        NCPrepareApplication();
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"NeuraChromiumSmokeData":data, @"ExtensionsPort":@(port)} forName:@"NeuraChromiumSmoke"];
        NCTabContextProbe *controller = [NCTabContextProbe new];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1000, 750) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        controller.window = window; window.title = @"neuraOS — Chrome tab context probe";
        NSMutableArray *tabs = [NSMutableArray array];
        @autoreleasepool {
            for (NSInteger i = 0; i < 2; ++i) {
                NCChromiumView *tab = [[NCChromiumView alloc] initWithFrame:NSMakeRect(180, 0, 820, 710) chromeTab:YES];
                tab.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                tab.hidden = i != 0;
                [tab loadURL:[base stringByAppendingFormat:@"/%ld", (long)i]];
                tab.onError = ^(NSString *error) {fprintf(stderr, "%s\n", error.UTF8String);};
                tab.onPopup = ^BOOL(NCChromiumView *popup, NSString *) {
                    popup.frame = NSMakeRect(180, 0, window.contentView.bounds.size.width - 180, window.contentView.bounds.size.height - 40);
                    popup.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    controller.tabs = [controller.tabs arrayByAddingObject:popup];
                    [window.contentView addSubview:popup]; return YES;
                };
                [window.contentView addSubview:tab]; [tabs addObject:tab];
                NSButton *button = [NSButton buttonWithTitle:[NSString stringWithFormat:@"Tab %ld", (long)i + 1] target:controller action:@selector(select:)];
                button.tag = i; button.frame = NSMakeRect(10, 660 - i * 40, 150, 30);
                button.autoresizingMask = NSViewMinYMargin; [window.contentView addSubview:button];
            }
            controller.tabs = tabs;
            [window makeKeyAndOrderFront:nil]; [tabs[0] synchronizeChromeTab]; [tabs[0] focusContent];
        }
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp activateIgnoringOtherApps:YES];
        __block BOOL stopping = NO;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *) {
            if (stopping) return;
            NSString *commandPath = [data stringByAppendingPathComponent:@"command.json"];
            NSData *bytes = [NSData dataWithContentsOfFile:commandPath];
            if (bytes) {
                NSDictionary *command = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
                [NSFileManager.defaultManager removeItemAtPath:commandPath error:nil];
                if (command[@"select"]) {NSButton *sender = [NSButton new]; sender.tag = [command[@"select"] integerValue]; if (sender.tag >= 0 && sender.tag < controller.tabs.count) [controller select:sender];}
                if (command[@"closePopup"] && controller.tabs.count > 2) {
                    NCChromiumView *popup = controller.tabs.lastObject; [popup close]; [popup removeFromSuperview];
                    controller.tabs = [controller.tabs subarrayWithRange:NSMakeRange(0, 2)];
                    NSButton *sender = [NSButton new]; sender.tag = 1; [controller select:sender];
                }
                if (command[@"resize"]) {[window setContentSize:NSMakeSize(850, 620)]; [window setFrameOrigin:NSMakePoint(150, 150)];}
                if (command[@"sheet"]) {NSAlert *alert = [NSAlert new]; alert.messageText = @"Native sheet acceptance"; [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse) {}];}
                if (command[@"dismissSheet"] && window.attachedSheet) [window endSheet:window.attachedSheet];
                NSMutableArray *states = [NSMutableArray array];
                for (NCChromiumView *tab in controller.tabs) {
                    NSWindow *surface = tab->_chromeNativeWindow;
                    [states addObject:@{@"browserId":@(tab->_browser ? tab->_browser->get_identifier(tab->_browser) : -1), @"chromeTab":@(tab.chromeTab), @"mappedOwner":@(NCChromiumOwnerForWindow(surface) == tab), @"visible":@(surface.visible), @"attached":@(surface.parentWindow == window), @"frame":NSStringFromRect(surface.frame), @"expected":NSStringFromRect([window convertRectToScreen:[tab convertRect:tab.bounds toView:nil]])}];
                }
                [[NSJSONSerialization dataWithJSONObject:@{@"selected":@(controller.selected), @"states":states} options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[data stringByAppendingPathComponent:@"state.json"] atomically:YES];
            }
            if ([NSFileManager.defaultManager fileExistsAtPath:[data stringByAppendingPathComponent:@"stop"]]) {
                stopping = YES;
                for (NCChromiumView *tab in controller.tabs) [tab close];
                NCShutdownChromium(^{
                    [@"completed" writeToFile:[data stringByAppendingPathComponent:@"shutdown.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    [NSApp stop:nil]; [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
                });
            }
        }];
        [NSApp run]; [timer invalidate]; [window orderOut:nil];
        return 0;
    }
}
