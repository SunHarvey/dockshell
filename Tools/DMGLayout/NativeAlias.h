#ifndef DOCKSHELL_DMG_NATIVE_ALIAS_H
#define DOCKSHELL_DMG_NATIVE_ALIAS_H

#include <CoreServices/CoreServices.h>
#include <string.h>

/* An alias made by Alias Manager for a mounted image includes a recursive
 * alias to the image's backing file (tag 20), the builder's mountpoint (19),
 * and sometimes its home-directory prefix (21). Those are useful for an alias
 * kept on that Mac, but not for a filesystem shipped to another Mac. Finder
 * must resolve the target on the currently mounted DockShell volume instead.
 *
 * Keep the real HFS+ volume creation time and file IDs, its volume-relative
 * target path, and the native Unicode/name records. Remove backing-image and
 * home hints, and replace the mountpoint hint with the conventional logical
 * path. This is an original, bounded serialization of the v2 AliasRecord
 * tagged-field format described by mac_alias's format implementation:
 * https://github.com/al45tair/mac_alias/blob/main/src/mac_alias/alias.py
 */
static inline CFDataRef _Nullable DockShellPortableFinderAlias(
    const UInt8 * _Nonnull bytes,
    Size length,
    int32_t * _Nonnull result
) CF_RETURNS_RETAINED {
    static const char target[] = "/.background/installer.tiff";
    static const char mountpoint[] = "/Volumes/DockShell";
    const size_t fixedLength = 150;
    if (length < (Size)(fixedLength + 4) || length > UINT16_MAX ||
        bytes[6] != 0 || bytes[7] != 2 ||
        (((UInt16)bytes[4] << 8) | bytes[5]) != (UInt16)length ||
        bytes[10] != 9 || memcmp(bytes + 11, "DockShell", 9) != 0) {
        *result = paramErr;
        return NULL;
    }
    /* A missing mount hint is appended below; allow growth, then enforce the
     * AliasRecord's UInt16 size limit before returning the bounded result. */
    CFMutableDataRef portable = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (portable == NULL) { *result = memFullErr; return NULL; }
    CFDataAppendBytes(portable, bytes, fixedLength);
    size_t offset = fixedLength;
    unsigned targetCount = 0;
    unsigned mountCount = 0;
    unsigned volumeDateCount = 0;
    unsigned targetDateCount = 0;
    UInt8 volumeDate[4] = {0};
    UInt8 targetDate[4] = {0};
    Boolean terminated = false;
    while (offset + 4 <= (size_t)length) {
        UInt16 tag = ((UInt16)bytes[offset] << 8) | bytes[offset + 1];
        UInt16 count = ((UInt16)bytes[offset + 2] << 8) | bytes[offset + 3];
        size_t field = offset;
        offset += 4;
        if (tag == UINT16_MAX) {
            terminated = count == 0 && offset == (size_t)length;
            break;
        }
        size_t padded = ((size_t)count + 1) & ~(size_t)1;
        if (padded > (size_t)length - offset) break;
        switch (tag) {
            case 0: case 1: case 2: case 14: case 15:
                CFDataAppendBytes(portable, bytes + field, 4 + padded);
                break;
            case 16: case 17:
                /* The native API writes legacy fixed-header dates in the
                 * builder's local time, but these 48.16 timestamp extensions
                 * are absolute HFS-epoch UTC values. Encode the fixed seconds
                 * from those same absolute dates so the shipped record does
                 * not depend on the CI host's timezone. */
                if (count != 8 || bytes[offset] != 0 || bytes[offset + 1] != 0) {
                    CFRelease(portable); *result = paramErr; return NULL;
                }
                if (tag == 16) {
                    ++volumeDateCount;
                    memcpy(volumeDate, bytes + offset + 2, sizeof(volumeDate));
                } else {
                    ++targetDateCount;
                    memcpy(targetDate, bytes + offset + 2, sizeof(targetDate));
                }
                CFDataAppendBytes(portable, bytes + field, 4 + padded);
                break;
            case 18:
                if (count != sizeof(target) - 1 ||
                    memcmp(bytes + offset, target, sizeof(target) - 1) != 0) {
                    CFRelease(portable); *result = paramErr; return NULL;
                }
                ++targetCount;
                CFDataAppendBytes(portable, bytes + field, 4 + padded);
                break;
            case 19:
                ++mountCount;
                /* Replaced once below, without the CI host's actual path. */
                break;
            case 20: case 21:
                /* Do not ship references to a deleted CI scratch image/home. */
                break;
            default:
                /* New native fields need an explicit portability review. */
                CFRelease(portable); *result = paramErr; return NULL;
        }
        offset += padded;
    }
    if (!terminated || targetCount != 1 || mountCount > 1 ||
        volumeDateCount != 1 || targetDateCount != 1) {
        CFRelease(portable); *result = paramErr; return NULL;
    }
    const UInt8 mountHeader[] = {0, 19, 0, sizeof(mountpoint) - 1};
    const UInt8 zero = 0;
    const UInt8 end[] = {0xff, 0xff, 0, 0};
    CFDataAppendBytes(portable, mountHeader, sizeof(mountHeader));
    CFDataAppendBytes(portable, (const UInt8 *)mountpoint, sizeof(mountpoint) - 1);
    if ((sizeof(mountpoint) - 1) & 1) CFDataAppendBytes(portable, &zero, 1);
    CFDataAppendBytes(portable, end, sizeof(end));
    CFIndex portableLength = CFDataGetLength(portable);
    if (portableLength > UINT16_MAX) {
        CFRelease(portable); *result = paramErr; return NULL;
    }
    UInt8 *header = CFDataGetMutableBytePtr(portable);
    header[4] = (UInt8)((UInt16)portableLength >> 8);
    header[5] = (UInt8)portableLength;
    memcpy(header + 38, volumeDate, sizeof(volumeDate));
    memcpy(header + 118, targetDate, sizeof(targetDate));
    /* The alias lives in the volume-root .DS_Store, and its target is one
     * directory below that root. These are the exact levels produced by
     * FSNewAliasFromPath("<volume>/.DS_Store", target, ...) for this layout.
     * An unanchored (-1, -1) alias can resolve through stale volume/container
     * hints; the relative form lets Finder use this installer's own root. */
    header[130] = 0; header[131] = 1;
    header[132] = 0; header[133] = 2;
    *result = noErr;
    return portable;
}

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
        ? DockShellPortableFinderAlias((const UInt8 *)*alias, length, result)
        : NULL;
    HUnlock((Handle)alias);
    DisposeHandle((Handle)alias);
    if (data == NULL && *result == noErr) *result = memFullErr;
    return data;
}

/* Resolve with the same Carbon Alias Manager origin used by Finder, rather
 * than converting to an unanchored NSURL bookmark. No kARMMountVol flag is
 * supplied: the target must be on an already mounted volume, without UI.
 * Alias Manager may update its temporary handle; the on-disk record remains
 * untouched, including when the installer volume is mounted read-only. */
static inline CFURLRef _Nullable DockShellResolveFinderAlias(
    CFDataRef _Nonnull data,
    const char * _Nonnull storeFilePath,
    int32_t * _Nonnull result
) CF_RETURNS_RETAINED {
    CFIndex length = CFDataGetLength(data);
    if (length < 154 || length > UINT16_MAX) {
        *result = paramErr;
        return NULL;
    }
    FSRef origin;
    *result = FSPathMakeRef((const UInt8 *)storeFilePath, &origin, NULL);
    if (*result != noErr) return NULL;
    AliasHandle alias = (AliasHandle)NewHandle((Size)length);
    if (alias == NULL) { *result = memFullErr; return NULL; }
    HLock((Handle)alias);
    memcpy(*alias, CFDataGetBytePtr(data), (size_t)length);
    HUnlock((Handle)alias);
    short count = 1;
    FSRef target;
    Boolean changed = false;
    *result = FSMatchAliasBulk(
        &origin, kARMNoUI | kARMSearchRelFirst | kARMTryFileIDFirst,
        alias, &count, &target, &changed, NULL, NULL
    );
    DisposeHandle((Handle)alias);
    if (*result != noErr) return NULL;
    if (count != 1) { *result = fnfErr; return NULL; }
    CFURLRef url = CFURLCreateFromFSRef(kCFAllocatorDefault, &target);
    if (url == NULL) *result = memFullErr;
    return url;
}
#pragma clang diagnostic pop

#endif
