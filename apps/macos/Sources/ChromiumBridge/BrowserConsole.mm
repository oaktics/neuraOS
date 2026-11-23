#import "ChromiumBridge.h"

static NSString *ConsolePrefix(NSString *value, NSUInteger limit) {
    if (value.length <= limit) return value;
    if (limit && CFStringIsSurrogateHighCharacter([value characterAtIndex:limit-1])) --limit;
    return [value substringToIndex:limit];
}
@implementation NCConsoleBuffer {
    NSMutableArray<NSDictionary *> *_entries;
    NSUInteger _dropped;
}
- (instancetype)init {if ((self = [super init])) _entries = [NSMutableArray array]; return self;}
- (void)appendLevel:(NSString *)level text:(NSString *)text sourceURL:(NSString *)url line:(NSInteger)line {
    NSAssert(NSThread.isMainThread, @"Console history belongs to the CEF UI thread");
    if (_entries.count == 500) {[_entries removeObjectAtIndex:0]; ++_dropped;}
    NSMutableDictionary *entry = [@{@"level":level, @"text":ConsolePrefix(text, 8192),
        @"timestamp":@([NSDate date].timeIntervalSince1970 * 1000)} mutableCopy];
    if (url.length) entry[@"url"] = ConsolePrefix(url, 2048);
    if (line > 0) entry[@"line"] = @(line);
    [_entries addObject:entry];
}
- (NSDictionary<NSString *, id> *)readLevel:(NSString *)level limit:(NSInteger)limit clear:(BOOL)clear {
    NSAssert(NSThread.isMainThread, @"Console history belongs to the CEF UI thread");
    NSMutableArray *selected = [NSMutableArray array];
    NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
    NSUInteger bytes = 1024, matches = 0;
    BOOL full = NO;
    limit = MAX(1, MIN(limit, 500));
    for (NSUInteger i = 0; i < _entries.count; ++i) {
        NSDictionary *entry = _entries[i];
        if (level && ![entry[@"level"] isEqual:level]) continue;
        ++matches;
        if (full || selected.count >= limit) continue;
        NSUInteger size = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil].length + 1;
        if (bytes + size > 256 * 1024) {full = YES; continue;}
        bytes += size; [selected addObject:entry]; [indices addIndex:i];
    }
    NSDictionary *result = @{@"entries":selected, @"hasMore":@(matches > selected.count), @"dropped":@(_dropped),
        @"untrusted":@YES, @"source":@"cef-console", @"timestampKind":@"received-unix-ms"};
    // Only returned entries are consumed: a filter or size cap must not silently lose unread logs.
    if (clear) [_entries removeObjectsAtIndexes:indices];
    return result;
}
@end
