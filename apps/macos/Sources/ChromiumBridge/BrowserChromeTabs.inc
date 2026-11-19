// Chrome Views preserves Chromium's Browser/TabStripModel and extension action
// dispatch. macOS parent_view would force Alloy, so keep the Views widget intact
// and attach its NSWindow as an AppKit child instead of reparenting its NSView.
template<class T> static void ChromeRelease(T *p) {
    if (p) {auto base = reinterpret_cast<cef_base_ref_counted_t *>(p); base->release(base);}
}
template<class T> static T *ChromeRetain(T *p) {
    if (p) {auto base = reinterpret_cast<cef_base_ref_counted_t *>(p); base->add_ref(base);}
    return p;
}
template<class T> struct ChromeDelegate {
    T api = {};
    std::atomic<int> refs{1};
    __weak NCChromiumView *view;
    explicit ChromeDelegate(NCChromiumView *owner): view(owner) {
        auto base = reinterpret_cast<cef_base_ref_counted_t *>(&api);
        base->size = sizeof(T);
        base->add_ref = [](cef_base_ref_counted_t *b) {++reinterpret_cast<ChromeDelegate *>(b)->refs;};
        base->release = [](cef_base_ref_counted_t *b) -> int {auto d = reinterpret_cast<ChromeDelegate *>(b); if (--d->refs == 0) {delete d; return 1;} return 0;};
        base->has_one_ref = [](cef_base_ref_counted_t *b) -> int {return reinterpret_cast<ChromeDelegate *>(b)->refs == 1;};
        base->has_at_least_one_ref = [](cef_base_ref_counted_t *b) -> int {return reinterpret_cast<ChromeDelegate *>(b)->refs > 0;};
    }
};

// CEF can hide or disable entries of Chrome's own menus but cannot add to them.
// The Views window is ours to lay out, so neuraOS actions get one button in the
// toolbar row and an AppKit menu.
static cef_image_t *ChromeSymbolImage(NSString *symbol, cef_color_t color) {
    auto image = p_cef_image_create();
    NSImage *source = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular]];
    if (!image || !source) return image;
    NSColor *tint = [NSColor colorWithSRGBRed:CefColorGetR(color) / 255.0 green:CefColorGetG(color) / 255.0 blue:CefColorGetB(color) / 255.0 alpha:CefColorGetA(color) / 255.0];
    const CGFloat side = 20;
    for (int scale = 1; scale <= 2; scale++) {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:side * scale pixelsHigh:side * scale
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        bitmap.size = NSMakeSize(side, side);
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        NSSize size = source.size;
        [source drawInRect:NSMakeRect((side - size.width) / 2, (side - size.height) / 2, size.width, size.height)];
        [tint set]; NSRectFillUsingOperation(NSMakeRect(0, 0, side, side), NSCompositingOperationSourceIn);
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        image->add_png(image, scale, png.bytes, png.length);
    }
    return image;
}
// `corner` is the button's bottom-right in its window, from the top-left.
static void ShowChromeMenu(NCChromiumView *owner, NSPoint corner, cef_menu_button_pressed_lock_t *lock) {
    // Menu tracking is a nested event loop. Start it from the run loop, not from a
    // main-queue block: that queue is serial and would stall until the menu closed.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
        // Never start it inside CEF's own work either.
        if (pumping) {ShowChromeMenu(owner, corner, lock); return;}
        NSWindow *window = owner ? owner->_chromeNativeWindow : nil;
        NSMenu *menu = window && owner.onToolbarMenu ? owner.onToolbarMenu() : nil;
        if (menu) {
            NSRect frame = window.frame;
            [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(frame) + corner.x - menu.size.width, NSMaxY(frame) - corner.y) inView:nil];
        }
        ChromeRelease(lock); // Keeps the button pressed while its menu is open.
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static cef_browser_view_delegate_t *ChromeBrowserDelegate(NCChromiumView *owner) {
    auto delegate = new ChromeDelegate<cef_browser_view_delegate_t>(owner);
    delegate->api.get_browser_runtime_style = [](cef_browser_view_delegate_t *) {return CEF_RUNTIME_STYLE_CHROME;};
    delegate->api.get_chrome_toolbar_type = [](cef_browser_view_delegate_t *, cef_browser_view_t *browser) {
        ChromeRelease(browser); return CEF_CTT_NORMAL;
    };
    delegate->api.base.on_window_changed = [](cef_view_delegate_t *s, cef_view_t *view, int added) {
        if (added) {
            NCChromiumView *owner = reinterpret_cast<ChromeDelegate<cef_browser_view_delegate_t> *>(s)->view;
            auto browser = view->as_browser_view(view);
            auto window = view->get_window(view);
            auto toolbar = browser ? browser->get_chrome_toolbar(browser) : nullptr;
            if (toolbar && window) {
                // Chrome creates the toolbar hidden until its embedder installs it.
                toolbar->set_visible(toolbar, 1);
                auto row = p_cef_panel_create(nullptr);
                cef_box_layout_settings_t settings = {}; settings.size = sizeof(settings);
                settings.horizontal = 1; settings.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH;
                auto layout = row->set_to_box_layout(row, &settings);
                row->add_child_view(row, ChromeRetain(toolbar));
                layout->set_flex_for_view(layout, ChromeRetain(toolbar), 1);
                ChromeRelease(layout);
                [owner installChromeMenuButton:row];
                window->base.add_child_view_at(&window->base, &row->base, 0);
                window->base.layout(&window->base);
            }
            ChromeRelease(toolbar); ChromeRelease(window); ChromeRelease(browser);
        }
        ChromeRelease(view);
    };
    delegate->api.get_delegate_for_popup_browser_view = [](cef_browser_view_delegate_t *, cef_browser_view_t *source, const cef_browser_settings_t *, cef_client_t *client, int devtools) -> cef_browser_view_delegate_t * {
        NCChromiumView *owner = devtools ? nil : View(client);
        cef_browser_view_delegate_t *result = owner ? ChromeBrowserDelegate(owner) : nullptr;
        ChromeRelease(source); Release(client); return result;
    };
    delegate->api.on_popup_browser_view_created = [](cef_browser_view_delegate_t *, cef_browser_view_t *source, cef_browser_view_t *popup, int devtools) -> int {
        auto browser = popup->get_browser(popup);
        auto host = browser ? browser->get_host(browser) : nullptr;
        auto client = host ? host->get_client(host) : nullptr;
        // The replacement client was installed by our OnBeforePopup. Chrome
        // may not deliver OnAfterCreated until this view enters a window.
        NCChromiumView *owner = !devtools && client ? View(client) : nil;
        Release(client); Release(host);
        if (owner) [owner adoptChromeView:ChromeRetain(popup)];
        Release(browser); ChromeRelease(source); ChromeRelease(popup);
        return owner != nil;
    };
    return &delegate->api;
}

@implementation NCChromiumView (ChromeTabs)
- (void)createChromeTab {
    cef_browser_settings_t settings = {}; settings.size = sizeof(settings);
    NCString address(_pendingURL);
    auto view = p_cef_browser_view_create(MakeClient(self), &address.value, &settings, nullptr, nullptr, ChromeBrowserDelegate(self));
    if (!view) {_creating = NO; if (self.onError) self.onError(@"Chromiumのタブを作成できませんでした。"); return;}
    [self adoptChromeView:view];
}
- (void)installChromeMenuButton:(cef_panel_t *)row {
    auto delegate = new ChromeDelegate<cef_menu_button_delegate_t>(self);
    delegate->api.on_menu_button_pressed = [](cef_menu_button_delegate_t *s, cef_menu_button_t *button, const cef_point_t *, cef_menu_button_pressed_lock_t *lock) {
        NCChromiumView *owner = reinterpret_cast<ChromeDelegate<cef_menu_button_delegate_t> *>(s)->view;
        auto view = &button->base.base.base;
        cef_size_t size = view->get_size(view);
        cef_point_t corner = {size.width, size.height};
        view->convert_point_to_window(view, &corner);
        ChromeRelease(button);
        ShowChromeMenu(owner, NSMakePoint(corner.x, corner.y), lock);
    };
    // Also runs when the button enters its window, once theme colors exist.
    delegate->api.base.base.on_theme_changed = [](cef_view_delegate_t *s, cef_view_t *view) {
        [reinterpret_cast<ChromeDelegate<cef_menu_button_delegate_t> *>(s)->view styleChromeMenuButton];
        ChromeRelease(view);
    };
    NCString text(@""), name(@"neuraOS メニュー");
    auto button = p_cef_menu_button_create(&delegate->api, &text.value);
    if (!button) return;
    button->base.base.set_tooltip_text(&button->base.base, &name.value);
    button->base.base.set_accessible_name(&button->base.base, &name.value);
    cef_size_t minimum = {40, 0}; button->base.set_minimum_size(&button->base, &minimum);
    ChromeRelease(_chromeMenuButton); _chromeMenuButton = button;
    row->add_child_view(row, ChromeRetain(&button->base.base.base));
}
- (void)styleChromeMenuButton {
    if (!_chromeMenuButton) return;
    auto label = &_chromeMenuButton->base; auto view = &label->base.base;
    auto window = view->get_window(view);
    if (!window) return;
    ChromeRelease(window);
    auto image = ChromeSymbolImage(self.toolbarSymbol ?: @"ellipsis.circle", view->get_theme_color(view, CEF_ColorToolbarButtonIcon));
    if (!image) return;
    for (auto state : {CEF_BUTTON_STATE_NORMAL, CEF_BUTTON_STATE_HOVERED, CEF_BUTTON_STATE_PRESSED}) label->set_image(label, state, ChromeRetain(image));
    ChromeRelease(image);
}
- (void)adoptChromeView:(cef_browser_view_t *)view {
    _chromeView = view;
    auto windowDelegate = new ChromeDelegate<cef_window_delegate_t>(self);
    windowDelegate->api.get_window_runtime_style = [](cef_window_delegate_t *) {return CEF_RUNTIME_STYLE_CHROME;};
    windowDelegate->api.is_frameless = [](cef_window_delegate_t *, cef_window_t *window) -> int {ChromeRelease(window); return 1;};
    windowDelegate->api.on_window_created = [](cef_window_delegate_t *s, cef_window_t *window) {
        chromeTabWindows.insert(s);
        NCChromiumView *owner = reinterpret_cast<ChromeDelegate<cef_window_delegate_t> *>(s)->view;
        if (owner && owner->_chromeView) {
            owner->_chromeWindow = ChromeRetain(window);
            cef_box_layout_settings_t settings = {}; settings.size = sizeof(settings); settings.horizontal = 0;
            auto layout = window->base.set_to_box_layout(&window->base, &settings);
            window->base.add_child_view(&window->base, ChromeRetain(&owner->_chromeView->base));
            layout->set_flex_for_view(layout, ChromeRetain(&owner->_chromeView->base), 1);
            ChromeRelease(layout);
        }
        ChromeRelease(window);
    };
    windowDelegate->api.can_close = [](cef_window_delegate_t *s, cef_window_t *window) -> int {
        NCChromiumView *owner = reinterpret_cast<ChromeDelegate<cef_window_delegate_t> *>(s)->view;
        int close = 1;
        if (owner && owner->_browser) {auto host = owner->_browser->get_host(owner->_browser); close = host->try_close_browser(host); Release(host);}
        ChromeRelease(window); return close;
    };
    windowDelegate->api.on_window_destroyed = [](cef_window_delegate_t *s, cef_window_t *window) {
        chromeTabWindows.erase(s);
        NCChromiumView *owner = reinterpret_cast<ChromeDelegate<cef_window_delegate_t> *>(s)->view;
        if (owner) {
            [owner detachChromeTab];
            ChromeRelease(owner->_chromeMenuButton); owner->_chromeMenuButton = nullptr;
            ChromeRelease(owner->_chromeWindow); owner->_chromeWindow = nullptr;
            ChromeRelease(owner->_chromeView); owner->_chromeView = nullptr;
            [chromeWindowOwners removeObjectForKey:owner->_chromeNativeWindow];
            owner->_chromeNativeWindow = nil;
        }
        ChromeRelease(window);
        CompleteShutdown();
    };
    auto window = p_cef_window_create_top_level(&windowDelegate->api);
    if (window) {
        NSView *native = (__bridge NSView *)window->get_window_handle(window);
        _chromeNativeWindow = native.window;
        if (!chromeWindowOwners) chromeWindowOwners = [NSMapTable weakToWeakObjectsMapTable];
        [chromeWindowOwners setObject:self forKey:_chromeNativeWindow];
        _chromeNativeWindow.hasShadow = NO;
        _chromeNativeWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
        // Layout and visibility follow the host without polling or navigating.
        _chromeObservers = [NSMutableArray array];
        __weak NCChromiumView *weakSelf = self;
        for (NSNotificationName name in @[NSWindowDidMoveNotification, NSWindowDidResizeNotification,
             NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification,
             NSWindowDidChangeOcclusionStateNotification, NSWindowWillBeginSheetNotification,
             NSWindowDidEndSheetNotification, NSViewFrameDidChangeNotification, NSViewBoundsDidChangeNotification]) {
            id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                NCChromiumView *owner = weakSelf;
                if (!owner || note.object == owner->_chromeNativeWindow) return;
                if ([note.object isKindOfClass:NSWindow.class] && note.object != owner.window) return;
                if ([note.object isKindOfClass:NSView.class] && ![owner isDescendantOf:note.object]) return;
                if ([note.name isEqualToString:NSWindowWillBeginSheetNotification]) owner->_chromeSheetPending = YES;
                if ([note.name isEqualToString:NSWindowDidEndSheetNotification]) {
                    owner->_chromeSheetPending = NO;
                    // AppKit may still expose attachedSheet during this notification.
                    dispatch_async(dispatch_get_main_queue(), ^{[weakSelf synchronizeChromeTab];});
                }
                [owner synchronizeChromeTab];
            }];
            [_chromeObservers addObject:observer];
        }
        ChromeRelease(window);
        [self synchronizeChromeTab];
    }
    _creating = NO;
    if (!_browser && self.onError) self.onError(@"Chromiumのタブを作成できませんでした。");
}
- (void)synchronizeChromeTab {
    if (!_chromeNativeWindow) return;
    NSWindow *parent = self.window;
    BOOL visible = !_closed && !shuttingDown && parent && parent.visible && !parent.miniaturized &&
        !parent.attachedSheet && !_chromeSheetPending && !self.hiddenOrHasHiddenAncestor && self.bounds.size.width > 0 && self.bounds.size.height > 0;
    if (!visible) {
        [_chromeNativeWindow.parentWindow removeChildWindow:_chromeNativeWindow];
        if (_chromeWindow) _chromeWindow->hide(_chromeWindow);
        return;
    }
    for (NSView *ancestor = self; ancestor; ancestor = ancestor.superview) {
        ancestor.postsFrameChangedNotifications = YES; ancestor.postsBoundsChangedNotifications = YES;
    }
    NSRect frame = [parent convertRectToScreen:[self convertRect:self.bounds toView:nil]];
    if (!NSEqualRects(_chromeNativeWindow.frame, frame)) [_chromeNativeWindow setFrame:frame display:YES];
    if (_chromeNativeWindow.parentWindow != parent) {
        [_chromeNativeWindow.parentWindow removeChildWindow:_chromeNativeWindow];
        [parent addChildWindow:_chromeNativeWindow ordered:NSWindowAbove];
    }
    if (!_chromeNativeWindow.visible && _chromeWindow) _chromeWindow->show(_chromeWindow);
}
- (void)detachChromeTab {
    for (id observer in _chromeObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [_chromeObservers removeAllObjects];
    [_chromeNativeWindow.parentWindow removeChildWindow:_chromeNativeWindow];
    [_chromeNativeWindow orderOut:nil];
}
@end
