/*
 * mount.c - Disc mounting utilities using DiskArbitration
 */

#include "mount.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <DiscRecording/DRCoreDevice.h>
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

static bool service_is_changer(io_registry_entry_t service) {
    CFTypeRef type = IORegistryEntryCreateCFProperty(
        service, CFSTR("Peripheral Device Type"), kCFAllocatorDefault, 0);
    if (!type) {
        type = IORegistryEntryCreateCFProperty(
            service, CFSTR("Device_Type"), kCFAllocatorDefault, 0);
    }
    int value = -1;
    bool result = type && CFGetTypeID(type) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)type, kCFNumberIntType, &value)
        && value == 8;
    if (type) CFRelease(type);
    return result;
}

/* Returns a retained physical FireWire unit ancestor, when present. */
static io_registry_entry_t copy_firewire_unit(io_registry_entry_t entry) {
    io_registry_entry_t current = entry;
    IOObjectRetain(current);
    while (current != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(current, "IOFireWireUnit")) {
            return current;
        }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        if (result != KERN_SUCCESS) return IO_OBJECT_NULL;
        current = parent;
    }
    return IO_OBJECT_NULL;
}

static io_registry_entry_t copy_changer_firewire_unit_for_class(const char *class_name) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMasterPortDefault, IOServiceMatching(class_name), &iterator);
    if (result != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_registry_entry_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (service_is_changer(service)) {
            io_registry_entry_t unit = copy_firewire_unit(service);
            IOObjectRelease(service);
            if (unit != IO_OBJECT_NULL) {
                IOObjectRelease(iterator);
                return unit;
            }
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);
    return IO_OBJECT_NULL;
}

static io_registry_entry_t copy_changer_firewire_unit(void) {
    io_registry_entry_t unit = copy_changer_firewire_unit_for_class("IOSCSIPeripheralDeviceNub");
    if (unit != IO_OBJECT_NULL) return unit;
    return copy_changer_firewire_unit_for_class("IOFireWireSBP2LUN");
}

static bool service_belongs_to_unit(io_registry_entry_t service, uint64_t expected_id) {
    io_registry_entry_t unit = copy_firewire_unit(service);
    if (unit == IO_OBJECT_NULL) return false;
    uint64_t actual_id = 0;
    bool matches = IORegistryEntryGetRegistryEntryID(unit, &actual_id) == KERN_SUCCESS
        && actual_id == expected_id;
    IOObjectRelease(unit);
    return matches;
}

static void collect_media_candidate(
    const char *class_name,
    bool restrict_to_unit,
    uint64_t unit_id,
    char **candidate,
    size_t *candidate_count
) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMasterPortDefault, IOServiceMatching(class_name), &iterator);
    if (result != KERN_SUCCESS) return;

    io_registry_entry_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (!restrict_to_unit || service_belongs_to_unit(service, unit_id)) {
            CFStringRef bsd_name = IORegistryEntryCreateCFProperty(
                service, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, 0);
            if (bsd_name) {
                char buffer[128];
                if (CFStringGetCString(bsd_name, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
                    if (*candidate == NULL || strcmp(*candidate, buffer) != 0) {
                        (*candidate_count)++;
                        if (*candidate == NULL) *candidate = strdup(buffer);
                    }
                }
                CFRelease(bsd_name);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
}

char *mount_find_dvd_bsd_name(void) {
    io_registry_entry_t changer_unit = copy_changer_firewire_unit();
    uint64_t unit_id = 0;
    bool restrict_to_unit = changer_unit != IO_OBJECT_NULL
        && IORegistryEntryGetRegistryEntryID(changer_unit, &unit_id) == KERN_SUCCESS;
    if (changer_unit != IO_OBJECT_NULL) IOObjectRelease(changer_unit);

    char *candidate = NULL;
    size_t candidate_count = 0;
    collect_media_candidate(kIODVDMediaClass, restrict_to_unit, unit_id, &candidate, &candidate_count);
    collect_media_candidate(kIOCDMediaClass, restrict_to_unit, unit_id, &candidate, &candidate_count);
    collect_media_candidate(kIOBDMediaClass, restrict_to_unit, unit_id, &candidate, &candidate_count);

    /* Never guess. Without a physical-unit match, a single system-wide optical
       disc is safe; multiple candidates are ambiguous and must be rejected. */
    if (candidate_count != 1) {
        free(candidate);
        return NULL;
    }
    return candidate;
}

bool mount_is_disc_present(void) {
    char *bsd = mount_find_dvd_bsd_name();
    if (bsd) {
        free(bsd);
        return true;
    }
    return false;
}

static char *mount_disc_with_path(
    const char *bsd_name,
    const char *mount_path,
    int timeout,
    bool nobrowse
) {
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

    CFURLRef mount_url = NULL;
    if (mount_path != NULL) {
        mount_url = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault,
            (const UInt8 *)mount_path,
            (CFIndex)strlen(mount_path),
            true
        );
        if (mount_url == NULL) {
            CFRelease(disk);
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            CFRelease(session);
            return NULL;
        }
    }

    DACallbackContext ctx = { false, 0, NULL };
    if (nobrowse) {
        CFStringRef arguments[] = { CFSTR("nobrowse"), NULL };
        DADiskMountWithArguments(
            disk,
            mount_url,
            kDADiskMountOptionDefault,
            da_mount_callback,
            &ctx,
            arguments
        );
    } else {
        DADiskMount(disk, mount_url, kDADiskMountOptionDefault, da_mount_callback, &ctx);
    }

    int elapsed = 0;
    while (!ctx.done && elapsed < timeout) {
        run_loop_for_seconds(1.0);
        elapsed++;
    }

    if (mount_url != NULL) CFRelease(mount_url);
    CFRelease(disk);
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);

    if (!ctx.done || ctx.result != 0) {
        return NULL;
    }

    /* Get the mount point after mounting */
    return mount_get_mount_point(bsd_name);
}

char *mount_disc(const char *bsd_name, int timeout) {
    return mount_disc_with_path(bsd_name, NULL, timeout, false);
}

char *mount_disc_at(const char *bsd_name, const char *mount_path, int timeout) {
    if (mount_path == NULL || mount_path[0] == '\0') return NULL;
    return mount_disc_with_path(bsd_name, mount_path, timeout, false);
}

char *mount_disc_nobrowse(const char *bsd_name, int timeout) {
    return mount_disc_with_path(bsd_name, NULL, timeout, true);
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

    int arbitration_result = ctx.done ? ctx.result : -1;
    if (arbitration_result == 0) return 0;

    /* A boot-time LaunchDaemon has no Aqua console session, so Disk
       Arbitration can reject eject with kDAReturnNotPrivileged even though
       the daemon has read access to the exact optical device. DiscRecording
       addresses the drive by BSD name and performs the same device-specific
       release without granting the web server root privileges. */
    CFStringRef name = CFStringCreateWithCString(
        kCFAllocatorDefault, bsd_name, kCFStringEncodingUTF8);
    if (name == NULL) return arbitration_result;
    DRDeviceRef device = DRDeviceCopyDeviceForBSDName(name);
    CFRelease(name);
    if (device == NULL) return arbitration_result;
    OSStatus recording_result = DRDeviceEjectMedia(device);
    CFRelease(device);
    return recording_result == noErr ? 0 : (int)recording_result;
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

    char *result = NULL;
    if (desc != NULL) {
        CFURLRef volumePath = CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey);
        if (volumePath) {
            char path[1024];
            if (CFURLGetFileSystemRepresentation(volumePath, true, (UInt8 *)path, sizeof(path))) {
                result = strdup(path);
            }
        }
        CFRelease(desc);
    }
    if (result != NULL) return result;

    /* A headless Catalina service can mount cddafs directly even when Disk
       Arbitration does not publish kDADiskDescriptionVolumePathKey. Consult
       the kernel mount table so these user-owned mounts are still visible to
       the rest of Discbot. */
    struct statfs *mounts = NULL;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    char expected[256];
    snprintf(expected, sizeof(expected), "/dev/%s", bsd_name);
    for (int index = 0; index < count; index++) {
        if (strcmp(mounts[index].f_mntfromname, expected) == 0) {
            return strdup(mounts[index].f_mntonname);
        }
    }
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
