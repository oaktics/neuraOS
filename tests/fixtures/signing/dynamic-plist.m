#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <unistd.h>
int main(void) { @autoreleasepool {
    NSBundle *bundle = NSBundle.mainBundle;
    NSMutableDictionary *info = [bundle.infoDictionary mutableCopy];
    [info removeObjectForKey:@"CFBundleNumericVersion"];
    NSError *error = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    NSData *raw = [NSData dataWithContentsOfURL:[bundle.bundleURL URLByAppendingPathComponent:@"Contents/Info.plist"]];
    if (!xml || !raw) return 2;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid:@(getpid()),
        (__bridge NSString *)kSecGuestAttributeDynamicCode:@YES,
        (__bridge NSString *)kSecGuestAttributeDynamicCodeInfoPlist:xml};
    SecCodeRef code = NULL;
    OSStatus copied = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code);
    OSStatus dynamic = copied ?: SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
    OSStatus chromium = copied ?: SecStaticCodeCheckValidity((SecStaticCodeRef)code, kSecCSBasicValidateOnly, NULL);
    if (code) CFRelease(code);
    printf("{\"equalBytes\":%s,\"rawBytes\":%lu,\"foundationBytes\":%lu,\"dynamicValidity\":%d,\"chromiumValidity\":%d}\n", [raw isEqualToData:xml]?"true":"false", (unsigned long)raw.length, (unsigned long)xml.length, (int)dynamic, (int)chromium);
    return 0;
} }
