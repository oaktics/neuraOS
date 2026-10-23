#import <Foundation/Foundation.h>
#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"
#include <dlfcn.h>
#include <cstring>
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *frameworks = [[NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent] stringByStandardizingPath];
        NSString *framework = [frameworks stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
        void *sandbox = dlopen([[framework stringByAppendingPathComponent:@"Libraries/libcef_sandbox.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
        if (!sandbox) return 1;
        auto initialize = (void *(*)(int, char **))dlsym(sandbox, "cef_sandbox_initialize");
        auto destroy = (void (*)(void *))dlsym(sandbox, "cef_sandbox_destroy");
        if (!initialize || !destroy) return 2;
        void *context = initialize(argc, argv); if (!context) return 3;
        void *library = dlopen([[framework stringByAppendingPathComponent:@"Chromium Embedded Framework"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
        if (!library) return 4;
        auto hash = (decltype(&cef_api_hash))dlsym(library, "cef_api_hash");
        auto execute = (decltype(&cef_execute_process))dlsym(library, "cef_execute_process");
        if (!hash || !execute) return 5;
        const char *apiHash = hash(CEF_API_VERSION, 0);
        if (!apiHash || strcmp(apiHash, CEF_API_HASH_PLATFORM)) return 5;
        cef_main_args_t args = {argc, argv};
        int result = execute(&args, nullptr, nullptr);
        destroy(context);
        return result;
    }
}
