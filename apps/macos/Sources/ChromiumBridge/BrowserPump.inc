// CEF's external-pump example caps fallback latency at 1000/30 ms.
// Keep all AppKit timers on the main thread, including callbacks from CEF IO.
static constexpr int64_t pumpFallbackMS = 1000 / 30;
static std::atomic<int64_t> requestedPumpDelay{0};
static std::atomic<bool> pumpRequestQueued{false};
static NSHashTable<NSMenu *> *trackingMenus;
static bool pumpDeferred = false, pumpFixed10Test = false;
static uint64_t pumpWakes = 0, pumpWorks = 0, pumpBlocked = 0, pumpReentries = 0;
static void ArmPump(int64_t delay);
static bool PumpBlocked() {
    if ((NSApp.modalWindow && !IsChromeWindow(NSApp.modalWindow)) || trackingMenus.count) return true;
    for (NSWindow *window in NSApp.windows) {
        // Chrome permission/install sheets require CEF dispatch. Native neuraOS
        // confirmations and file dialogs must retain their own AppKit dispatch.
        if ((window.attachedSheet || window.sheetParent) && !IsChromeWindow(window)) return true;
    }
    return false;
}
static void PumpWork() {
    ++pumpWakes;
    if (!initialized) return;
    if (pumping) {++pumpReentries; pumpDeferred = true; return;}
    if (shuttingDown && browsers.empty()) {CompleteShutdown(); return;}
    if (PumpBlocked()) {++pumpBlocked; ArmPump(pumpFixed10Test ? 10 : pumpFallbackMS); return;}
    pumping = true;
    ++pumpWorks;
    @try {p_cef_do_message_loop_work();} @finally {pumping = false;}
    if (pumpDeferred) {pumpDeferred = false; ArmPump(0);}
    else if (!pump) ArmPump(pumpFixed10Test ? 10 : pumpFallbackMS);
}
static void ArmPump(int64_t delay) {
    if (!initialized) return;
    [pump invalidate];
    // A zero-delay timer yields to AppKit instead of recursively entering CEF.
    const double seconds = MAX(0, MIN(delay, pumpFallbackMS)) / 1000.0;
    pump = [NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer *fired) {
        if (pump != fired) return;
        pump = nil;
        PumpWork();
    }];
    // Common modes also run during native tracking; deliberately use default.
    [NSRunLoop.mainRunLoop addTimer:pump forMode:NSDefaultRunLoopMode];
}
static void RequestPump(int64_t delay) {
    requestedPumpDelay.store(delay);
    if (pumpRequestQueued.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        pumpRequestQueued.store(false);
        if (!pumpFixed10Test) ArmPump(requestedPumpDelay.load());
    });
}
static void StartPump() {
    trackingMenus = [NSHashTable weakObjectsHashTable];
    [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [trackingMenus addObject:note.object];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [trackingMenus removeObject:note.object];
        RequestPump(0);
    }];
    if (pumpFixed10Test) {
        pump = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *) {PumpWork();}];
        [NSRunLoop.mainRunLoop addTimer:pump forMode:NSDefaultRunLoopMode];
    } else ArmPump(0);
}
