/*
 * mount.c - Disc mounting utilities using DiskArbitration
 */

#include "mount.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOCDMedia.h>
#include <IOKit/storage/IODVDMedia.h>
#include <IOKit/storage/IOBDMedia.h>

/* Helper to run a run loop for a given duration */
static void run_loop_for_seconds(double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

/* Callback context for async DA operations */
typedef struct {
    bool done;
    int result;
    char *mount_point;
} DACallbackContext;

/* DA mount callback */
static void da_mount_callback(DADiskRef disk, DADissenterRef dissenter, void *context) {
    DACallbackContext *ctx = (DACallbackContext *)context;
    if (dissenter) {
        ctx->result = (int)DADissenterGetStatus(dissenter);
    } else {
        ctx->result = 0;
    }
    ctx->done = true;
}

/* DA unmount/eject callback */
static void da_unmount_callback(DADiskRef disk, DADissenterRef dissenter, void *context) {
    DACallbackContext *ctx = (DACallbackContext *)context;
    if (dissenter) {
        ctx->result = (int)DADissenterGetStatus(dissenter);
    } else {
        ctx->result = 0;
    }
    ctx->done = true;
}

int mount_wait_for_disc(int timeout) {
    int elapsed = 0;
    while (elapsed < timeout) {
        if (mount_is_disc_present()) {
            return 0;
        }
        sleep(1);
        elapsed++;
    }
    return -1;
}

char *mount_find_dvd_bsd_name(void) {
    io_iterator_t iter;
    io_object_t service;
    char *result = NULL;

    /* Try DVD media first */
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMasterPortDefault,
        IOServiceMatching(kIODVDMediaClass),
        &iter
    );

    if (kr == KERN_SUCCESS) {
        service = IOIteratorNext(iter);
        if (service) {
            CFStringRef bsdName = IORegistryEntryCreateCFProperty(
                service, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, 0
            );
            if (bsdName) {
                char buf[128];
                if (CFStringGetCString(bsdName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    result = strdup(buf);
                }
                CFRelease(bsdName);
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
        if (result) return result;
    }

    /* Try CD media */
    kr = IOServiceGetMatchingServices(
        kIOMasterPortDefault,
        IOServiceMatching(kIOCDMediaClass),
        &iter
    );

    if (kr == KERN_SUCCESS) {
        service = IOIteratorNext(iter);
        if (service) {
            CFStringRef bsdName = IORegistryEntryCreateCFProperty(
                service, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, 0
            );
            if (bsdName) {
                char buf[128];
                if (CFStringGetCString(bsdName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    result = strdup(buf);
                }
                CFRelease(bsdName);
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
        if (result) return result;
    }

    /* Try BD (Blu-ray) media */
    kr = IOServiceGetMatchingServices(
        kIOMasterPortDefault,
        IOServiceMatching(kIOBDMediaClass),
        &iter
    );

    if (kr == KERN_SUCCESS) {
        service = IOIteratorNext(iter);
        if (service) {
            CFStringRef bsdName = IORegistryEntryCreateCFProperty(
                service, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, 0
            );
            if (bsdName) {
                char buf[128];
                if (CFStringGetCString(bsdName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    result = strdup(buf);
                }
                CFRelease(bsdName);
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
    }

    return result;
}

bool mount_is_disc_present(void) {
    char *bsd = mount_find_dvd_bsd_name();
    if (bsd) {
        free(bsd);
        return true;
    }
    return false;
}

char *mount_disc(const char *bsd_name, int timeout) {
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return NULL;

    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    char dev_path[256];
    snprintf(dev_path, sizeof(dev_path), "/dev/%s", bsd_name);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, dev_path);
    if (!disk) {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return NULL;
    }

    DACallbackContext ctx = { false, 0, NULL };
    DADiskMount(disk, NULL, kDADiskMountOptionDefault, da_mount_callback, &ctx);

    int elapsed = 0;
    while (!ctx.done && elapsed < timeout) {
        run_loop_for_seconds(1.0);
        elapsed++;
    }

    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);

    if (!ctx.done || ctx.result != 0) {
        return NULL;
    }

    /* Get the mount point after mounting */
    return mount_get_mount_point(bsd_name);
}

int mount_unmount_disc(const char *bsd_name, bool force) {
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return -1;

    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    char dev_path[256];
    snprintf(dev_path, sizeof(dev_path), "/dev/%s", bsd_name);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, dev_path);
    if (!disk) {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return -1;
    }

    DACallbackContext ctx = { false, 0, NULL };
    DADiskUnmountOptions options = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault;
    DADiskUnmount(disk, options, da_unmount_callback, &ctx);

    int elapsed = 0;
    while (!ctx.done && elapsed < 30) {
        run_loop_for_seconds(1.0);
        elapsed++;
    }

    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);

    return ctx.done ? ctx.result : -1;
}

int mount_eject_disc(const char *bsd_name, bool force) {
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return -1;

    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    char dev_path[256];
    snprintf(dev_path, sizeof(dev_path), "/dev/%s", bsd_name);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, dev_path);
    if (!disk) {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(session);
        return -1;
    }

    DACallbackContext ctx = { false, 0, NULL };
    DADiskEjectOptions options = force ? kDADiskEjectOptionDefault : kDADiskEjectOptionDefault;
    DADiskEject(disk, options, da_unmount_callback, &ctx);

    int elapsed = 0;
    while (!ctx.done && elapsed < 30) {
        run_loop_for_seconds(1.0);
        elapsed++;
    }

    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);

    return ctx.done ? ctx.result : -1;
}

bool mount_is_mounted(const char *bsd_name) {
    char *mp = mount_get_mount_point(bsd_name);
    if (mp) {
        free(mp);
        return true;
    }
    return false;
}

char *mount_get_mount_point(const char *bsd_name) {
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return NULL;

    char dev_path[256];
    snprintf(dev_path, sizeof(dev_path), "/dev/%s", bsd_name);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, dev_path);
    if (!disk) {
        CFRelease(session);
        return NULL;
    }

    CFDictionaryRef desc = DADiskCopyDescription(disk);
    CFRelease(disk);
    CFRelease(session);

    if (!desc) return NULL;

    char *result = NULL;
    CFURLRef volumePath = CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey);
    if (volumePath) {
        char path[1024];
        if (CFURLGetFileSystemRepresentation(volumePath, true, (UInt8 *)path, sizeof(path))) {
            result = strdup(path);
        }
    }

    CFRelease(desc);
    return result;
}

char *mount_get_volume_name(const char *bsd_name) {
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return NULL;

    char dev_path[256];
    snprintf(dev_path, sizeof(dev_path), "/dev/%s", bsd_name);

    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, dev_path);
    if (!disk) {
        CFRelease(session);
        return NULL;
    }

    CFDictionaryRef desc = DADiskCopyDescription(disk);
    CFRelease(disk);
    CFRelease(session);

    if (!desc) return NULL;

    char *result = NULL;
    CFStringRef volumeName = CFDictionaryGetValue(desc, kDADiskDescriptionVolumeNameKey);
    if (volumeName) {
        char name[512];
        if (CFStringGetCString(volumeName, name, sizeof(name), kCFStringEncodingUTF8)) {
            result = strdup(name);
        }
    }

    CFRelease(desc);
    return result;
}
