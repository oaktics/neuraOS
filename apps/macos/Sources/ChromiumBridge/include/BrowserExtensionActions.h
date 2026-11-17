#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@class NCChromiumView;
@interface NCExtensionAction : NSObject
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly, nullable) NSString *popupURL;
@property(nonatomic, readonly, nullable) NSImage *icon;
@end
// Reads a copy of Chromium's live preferences, never writes extension settings.
FOUNDATION_EXPORT NSArray<NCExtensionAction *> *NCExtensionActions(void);
// Deterministic catalog reader, also used by isolated tests. profile is Chromium/Default.
FOUNDATION_EXPORT NSArray<NCExtensionAction *> *NCReadExtensionActions(NSDictionary *settings, NSString *profile);
// An extension document host, not a Chrome action invocation or activeTab grant.
@interface NCExtensionPopover : NSObject <NSPopoverDelegate>
- (nullable NSString *)showExtension:(NSString *)identifier fromView:(NSView *)anchor source:(NCChromiumView *)source;
- (void)close;
@end
NS_ASSUME_NONNULL_END
