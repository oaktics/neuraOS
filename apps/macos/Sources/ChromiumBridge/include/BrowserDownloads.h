#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface NCDownload : NSObject
@property(nonatomic, readonly) NSUInteger identifier;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *path;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSString *detail;
@property(nonatomic, readonly) int64_t received;
@property(nonatomic, readonly) int64_t total;
- (void)cancel;
- (void)reveal;
@end
FOUNDATION_EXPORT NSArray<NCDownload *> *NCBrowserDownloads(void);
FOUNDATION_EXPORT NSNotificationName const NCBrowserDownloadsChanged;
NS_ASSUME_NONNULL_END
// Pure callback regression check; never initializes CEF or writes files.
FOUNDATION_EXPORT BOOL NCVerifyDownloadTerminalStates(void);
