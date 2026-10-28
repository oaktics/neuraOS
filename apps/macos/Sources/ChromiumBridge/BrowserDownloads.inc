// Included by ChromiumBridge.mm so CEF ownership helpers remain shared.
#import "BrowserDownloads.h"
#include "include/capi/cef_download_handler_capi.h"
NSNotificationName const NCBrowserDownloadsChanged = @"NCBrowserDownloadsChanged";
static NSMutableArray<NCDownload *> *downloadHistory;
// Configured only by the isolated loopback smoke entry point. Production always presents NSSavePanel.
static void (^downloadSmokeChoose)(NSSavePanel *, NSWindow *, void (^)(NSURL *));
@interface NCDownload () {
@public
    cef_before_download_callback_t *_before;
    cef_download_item_callback_t *_control;
    int _browserID;
    BOOL _cancelRequested;
    NSUInteger _selectionGeneration;
    NSSavePanel *_panel;
}
@property(nonatomic) NSUInteger identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *status;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic) int64_t received;
@property(nonatomic) int64_t total;
@end
static BOOL DownloadTerminal(NCDownload *download) {
    return [@[@"complete", @"failed", @"canceled"] containsObject:download.status];
}
static void DownloadsChanged() {
    // Deliver outside CEF's callbacks, avoiding SwiftUI publication during layout.
    dispatch_async(dispatch_get_main_queue(), ^{[NSNotificationCenter.defaultCenter postNotificationName:NCBrowserDownloadsChanged object:nil];});
}
@implementation NCDownload
- (void)cancel {
    if (![@[@"choosing", @"running"] containsObject:self.status]) return;
    _cancelRequested = YES;
    self.status = @"canceled"; self.detail = @"キャンセルしました";
    [_panel cancel:nil];
    if (_control) {auto control = _control; _control = nullptr; control->cancel(control); Release(control);}
    auto before = _before; _before = nullptr; Release(before);
    DownloadsChanged();
}
- (void)reveal {if ([self.status isEqualToString:@"complete"] && self.path.length) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.path]]];}
- (void)dealloc {Release(_before); Release(_control);}
@end
NSArray<NCDownload *> *NCBrowserDownloads(void) {return downloadHistory.copy ?: @[];}
static NCDownload *Download(uint32_t identifier, int browserID) {
    if (!downloadHistory) downloadHistory = [NSMutableArray array];
    for (NCDownload *item in downloadHistory) if (item.identifier == identifier) return item;
    NCDownload *item = [NCDownload new]; item.identifier = identifier; item->_browserID = browserID;
    item.name = @"ダウンロード"; item.path = @""; item.status = @"choosing"; item.detail = @"保存先を選択";
    [downloadHistory insertObject:item atIndex:0];
    return item;
}
static void CloseDownloads(int browserID) {
    for (NCDownload *item in downloadHistory.copy) if (item->_browserID == browserID) [item cancel];
}
static NSString *DownloadString(cef_string_userfree_t value) {
    NSString *result = String(value);
    if (value) p_cef_string_userfree_utf16_free(value);
    return result;
}
// A save response can arrive after a failure/close callback. Bind it to the exact
// retained continuation and generation; terminal records can never be revived.
static void SelectDownloadDestination(NCDownload *download, cef_before_download_callback_t *expected,
                                      NSUInteger generation, NCChromiumView *owner, NSURL *url) {
    if (!expected || DownloadTerminal(download) || download->_before != expected || download->_selectionGeneration != generation) return;
    download->_panel = nil;
    if (!url || download->_cancelRequested || !owner || owner->_closed) {[download cancel]; return;}
    download.path = url.path; download.name = url.lastPathComponent;
    download.status = @"running"; download.detail = @"ダウンロード中";
    auto continuation = download->_before; download->_before = nullptr;
    NCString path(download.path); continuation->cont(continuation, &path.value, 0); Release(continuation);
    DownloadsChanged();
}
static cef_download_handler_t *MakeDownloadHandler(NCChromiumView *view) {
    auto h = new Handler<cef_download_handler_t>(view);
    h->api.can_download = [](cef_download_handler_t *, cef_browser_t *browser, const cef_string_t *, const cef_string_t *) -> int {CallbackRef ref(browser); return 1;};
    h->api.on_before_download = [](cef_download_handler_t *self, cef_browser_t *browser, cef_download_item_t *item, const cef_string_t *suggested, cef_before_download_callback_t *callback) -> int {
        CallbackRef browserRef(browser); CallbackRef itemRef(item);
        if (!item->is_valid(item)) {Release(callback); return 1;}
        NCDownload *download = Download(item->get_id(item), browser->get_identifier(browser));
        if (DownloadTerminal(download) || download->_cancelRequested || download->_before) {Release(callback); return 1;}
        download->_before = callback; // Adopt until the asynchronous save panel finishes.
        NSUInteger generation = ++download->_selectionGeneration;
        NSString *name = String(suggested).lastPathComponent;
        download.name = name.length ? name : @"download";
        __weak NCChromiumView *weakView = View(self);
        DownloadsChanged();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (DownloadTerminal(download) || download->_before != callback || download->_selectionGeneration != generation || download->_cancelRequested) return;
            NCChromiumView *owner = weakView;
            if (!owner || owner->_closed || !owner.window) {[download cancel]; return;}
            NSSavePanel *panel = [NSSavePanel savePanel]; download->_panel = panel;
            panel.title = @"ダウンロードを保存"; panel.nameFieldStringValue = download.name;
            panel.canCreateDirectories = YES;
            void (^selected)(NSURL *) = ^(NSURL *url) {
                SelectDownloadDestination(download, callback, generation, owner, url);
            };
            if (downloadSmokeChoose) downloadSmokeChoose(panel, owner.window, selected);
            else [panel beginSheetModalForWindow:owner.window completionHandler:^(NSModalResponse response) {
                selected(response == NSModalResponseOK ? panel.URL : nil);
            }];
        });
        return 1;
    };
    h->api.on_download_updated = [](cef_download_handler_t *, cef_browser_t *browser, cef_download_item_t *item, cef_download_item_callback_t *callback) {
        CallbackRef browserRef(browser); CallbackRef itemRef(item);
        if (!item->is_valid(item)) {Release(callback); return;}
        NCDownload *download = Download(item->get_id(item), browser ? browser->get_identifier(browser) : 0);
        if (DownloadTerminal(download)) {Release(callback); return;}
        Release(download->_control); download->_control = callback;
        download.received = item->get_received_bytes(item); download.total = item->get_total_bytes(item);
        NSString *path = DownloadString(item->get_full_path(item));
        if (path.length) download.path = path;
        if (download->_cancelRequested || item->is_canceled(item)) {download.status = @"canceled"; download.detail = @"キャンセルしました";}
        else if (item->is_complete(item)) {download.status = @"complete"; download.detail = @"完了";}
        else if (item->is_interrupted(item)) {
            download.status = @"failed";
            download.detail = [NSString stringWithFormat:@"ダウンロードに失敗しました（エラー %d）。保存先の空き容量・権限や接続を確認し、再度お試しください。", (int)item->get_interrupt_reason(item)];
        }
        if (download->_cancelRequested && item->is_in_progress(item) && callback) callback->cancel(callback);
        if (![@[@"choosing", @"running"] containsObject:download.status]) {
            auto control = download->_control; download->_control = nullptr; Release(control);
            auto before = download->_before; download->_before = nullptr; Release(before);
            NSSavePanel *panel = download->_panel; download->_panel = nil; [panel cancel:nil];
        }
        DownloadsChanged();
    };
    return &h->api;
}
