#ifndef DOCKSHELL_DMG_NATIVE_ALIAS_H
#define DOCKSHELL_DMG_NATIVE_ALIAS_H

#include <CoreServices/CoreServices.h>

/* Finder's icon-view backgroundImageAlias still consumes a Carbon AliasRecord,
 * not NSURL bookmark data. Keep this deprecated compatibility API confined to
 * the build helper; it is never linked into DockShell.app. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline CFDataRef _Nullable DockShellCreateFinderAlias(
    const char * _Nonnull path,
    int32_t * _Nonnull result
) CF_RETURNS_RETAINED {
    AliasHandle alias = NULL;
    *result = FSNewAliasFromPath(NULL, path, 0, &alias, NULL);
    if (*result != noErr || alias == NULL) {
        if (alias != NULL) DisposeHandle((Handle)alias);
        if (*result == noErr) *result = memFullErr;
        return NULL;
    }
    HLock((Handle)alias);
    Size length = GetHandleSize((Handle)alias);
    CFDataRef data = length > 0
        ? CFDataCreate(kCFAllocatorDefault, (const UInt8 *)*alias, length)
        : NULL;
    HUnlock((Handle)alias);
    DisposeHandle((Handle)alias);
    if (data == NULL) *result = memFullErr;
    return data;
}
#pragma clang diagnostic pop

#endif
