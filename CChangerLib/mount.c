#include "mount.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IODVDMedia.h>
#include <IOKit/storage/IOCDMedia.h>
#include <DiskArbitration/DiskArbitration.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/param.h>

// Context for mount/unmount callbacks
typedef struct {
    bool done;
    DADissenterRef dissenter;
    char mount_point[MAXPATHLEN];
} DACallbackContext;

static void mount_callback(DADiskRef disk, DADissenterRef dissenter,
                           void *context) {
    DACallbackContext *ctx = (DACallbackContext *)context;
    ctx->dissenter = dissenter;

    if (!dissenter && disk) {
        // Get mount point from disk description
        CFDictionaryRef desc = DADiskCopyDescription(disk);
        if (desc) {
            CFURLRef path = CFDictionaryGetValue(desc,
                kDADiskDescriptionVolumePathKey);
            if (path) {
                CFURLGetFileSystemRepresentation(path, true,
                    (UInt8 *)ctx->mount_point, sizeof(ctx->mount_point));
            }
            CFRelease(desc);
        }
    }

    ctx->done = true;
}

static void unmount_callback(DADiskRef disk, DADissenterRef dissenter,
                             void *context) {
    (void)disk;
    DACallbackContext *ctx = (DACallbackContext *)context;
    ctx->dissenter = dissenter;
    ctx->done = true;
}

// Run the run loop until done or timeout
static bool da_runloop_wait(bool *done, double timeout_sec) {
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + timeout_sec;
    while (!*done) {
        CFTimeInterval remaining = end - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) {
            return false;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                           remaining > 0.1 ? 0.1 : remaining, true);
    }
    return true;
}

char *mount_find_dvd_bsd_name(void) {
    io_iterator_t iter = IO_OBJECT_NULL;
    io_service_t service = IO_OBJECT_NULL;
    char *bsd_name = NULL;

    // Try DVD media first
    CFMutableDictionaryRef match = IOServiceMatching(kIODVDMediaClass);
    if (match) {
        kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                        match, &iter);
        if (kr == KERN_SUCCESS && iter != IO_OBJECT_NULL) {
            service = IOIteratorNext(iter);
            IOObjectRelease(iter);
        }
    }

    // Fall back to CD media
    if (service == IO_OBJECT_NULL) {
        match = IOServiceMatching(kIOCDMediaClass);
        if (match) {
            kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                            match, &iter);
            if (kr == KERN_SUCCESS && iter != IO_OBJECT_NULL) {
                service = IOIteratorNext(iter);
                IOObjectRelease(iter);
            }
        }
    }

    if (service != IO_OBJECT_NULL) {
        CFTypeRef bsd_prop = IORegistryEntryCreateCFProperty(
            service, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
        if (bsd_prop && CFGetTypeID(bsd_prop) == CFStringGetTypeID()) {
            char buf[64];
            if (CFStringGetCString((CFStringRef)bsd_prop, buf, sizeof(buf),
                                   kCFStringEncodingUTF8)) {
                bsd_name = strdup(buf);
            }
            CFRelease(bsd_prop);
        }
        IOObjectRelease(service);
    }

    return bsd_name;
}

int mount_wait_for_disc(int timeout_seconds) {
    time_t start = time(NULL);

    while (time(NULL) - start < timeout_seconds) {
        char *bsd = mount_find_dvd_bsd_name();
        if (bsd) {
            free(bsd);
            return 0;
        }
        usleep(500000); // 500ms
    }

    return -1;
}

bool mount_is_disc_present(void) {
    char *bsd = mount_find_dvd_bsd_name();
    if (bsd) {
        free(bsd);
        return true;
    }
    return false;
}

char *mount_disc(const char *bsd_name, int timeout_seconds) {
    if (!bsd_name) return NULL;

    // Create full device path if needed
    char dev_path[128];
    if (bsd_name[0] == '/') {
        snprintf(dev_path, sizeof(dev_path), "%s", bsd_name);
    } else {
        snprintf(dev_path, sizeof(dev_path), "/dev/%s", bsd_name);
    }

    // Extract just the BSD name for DiskArbitration
    const char *name = bsd_name;
    if (strncmp(name, "/dev/", 5) == 0) {
        name = name + 5;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) {
        fprintf(stderr, "Failed to create DiskArbitration session\n");
        return NULL;
    }

    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(),
                                 kCFRunLoopDefaultMode);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name);
    if (!disk) {
        fprintf(stderr, "Failed to create DADisk for %s\n", name);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return NULL;
    }

    DACallbackContext ctx = {0};

    DADiskMount(disk, NULL, kDADiskMountOptionDefault, mount_callback, &ctx);

    if (!da_runloop_wait(&ctx.done, timeout_seconds)) {
        fprintf(stderr, "Mount timed out\n");
        CFRelease(disk);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return NULL;
    }

    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                   kCFRunLoopDefaultMode);
    CFRelease(session);

    if (ctx.dissenter) {
        DAReturn status = DADissenterGetStatus(ctx.dissenter);
        fprintf(stderr, "Mount failed: 0x%x\n", status);
        return NULL;
    }

    if (ctx.mount_point[0]) {
        return strdup(ctx.mount_point);
    }

    return NULL;
}

int mount_unmount_disc(const char *bsd_name, bool force) {
    if (!bsd_name) return -1;

    const char *name = bsd_name;
    if (strncmp(name, "/dev/", 5) == 0) {
        name = name + 5;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) {
        return -1;
    }

    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(),
                                 kCFRunLoopDefaultMode);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name);
    if (!disk) {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return -1;
    }

    DACallbackContext ctx = {0};
    DADiskUnmountOptions options = kDADiskUnmountOptionDefault;
    if (force) {
        options |= kDADiskUnmountOptionForce;
    }

    DADiskUnmount(disk, options, unmount_callback, &ctx);

    if (!da_runloop_wait(&ctx.done, 30.0)) {
        CFRelease(disk);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return -1;
    }

    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                   kCFRunLoopDefaultMode);
    CFRelease(session);

    if (ctx.dissenter) {
        return (int)DADissenterGetStatus(ctx.dissenter);
    }

    return 0;
}

bool mount_is_mounted(const char *bsd_name) {
    if (!bsd_name) return false;

    const char *name = bsd_name;
    if (strncmp(name, "/dev/", 5) == 0) {
        name = name + 5;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return false;

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name);
    if (!disk) {
        CFRelease(session);
        return false;
    }

    CFDictionaryRef desc = DADiskCopyDescription(disk);
    CFRelease(disk);
    CFRelease(session);

    if (!desc) return false;

    CFURLRef path = CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey);
    bool mounted = (path != NULL);

    CFRelease(desc);
    return mounted;
}

char *mount_get_mount_point(const char *bsd_name) {
    if (!bsd_name) return NULL;

    const char *name = bsd_name;
    if (strncmp(name, "/dev/", 5) == 0) {
        name = name + 5;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return NULL;

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name);
    if (!disk) {
        CFRelease(session);
        return NULL;
    }

    CFDictionaryRef desc = DADiskCopyDescription(disk);
    CFRelease(disk);
    CFRelease(session);

    if (!desc) return NULL;

    CFURLRef path = CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey);
    char *result = NULL;

    if (path) {
        char buf[MAXPATHLEN];
        if (CFURLGetFileSystemRepresentation(path, true, (UInt8 *)buf,
                                             sizeof(buf))) {
            result = strdup(buf);
        }
    }

    CFRelease(desc);
    return result;
}

char *mount_get_volume_name(const char *bsd_name) {
    if (!bsd_name) return NULL;

    const char *name = bsd_name;
    if (strncmp(name, "/dev/", 5) == 0) {
        name = name + 5;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return NULL;

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name);
    if (!disk) {
        CFRelease(session);
        return NULL;
    }

    CFDictionaryRef desc = DADiskCopyDescription(disk);
    CFRelease(disk);
    CFRelease(session);

    if (!desc) return NULL;

    CFStringRef volName = CFDictionaryGetValue(desc,
        kDADiskDescriptionVolumeNameKey);
    char *result = NULL;

    if (volName && CFGetTypeID(volName) == CFStringGetTypeID()) {
        char buf[256];
        if (CFStringGetCString(volName, buf, sizeof(buf),
                               kCFStringEncodingUTF8)) {
            result = strdup(buf);
        }
    }

    CFRelease(desc);
    return result;
}

int mount_eject_disc(const char *bsd_name, bool force) {
    if (!bsd_name) return -1;

    const char *name = bsd_name;
    if (strncmp(name, "/dev/", 5) == 0) {
        name = name + 5;
    }

    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) {
        return -1;
    }

    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(),
                                 kCFRunLoopDefaultMode);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name);
    if (!disk) {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return -1;
    }

    DACallbackContext ctx = {0};
    (void)force; // DADiskEject doesn't have a force option

    // DADiskEject unmounts and ejects the media
    DADiskEject(disk, kDADiskEjectOptionDefault, unmount_callback, &ctx);

    if (!da_runloop_wait(&ctx.done, 30.0)) {
        CFRelease(disk);
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
        CFRelease(session);
        return -1;
    }

    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(),
                                   kCFRunLoopDefaultMode);
    CFRelease(session);

    if (ctx.dissenter) {
        return (int)DADissenterGetStatus(ctx.dissenter);
    }

    return 0;
}
