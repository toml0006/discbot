#include "sbp2.h"
#include "scsi.h"
#include <IOKit/scsi/SCSICmds_REQUEST_SENSE_Defs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ============================================================
// Helper functions
// ============================================================

static bool cfstring_equals(CFTypeRef value, const char *expected) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return false;
    }
    char buf[256];
    if (!CFStringGetCString((CFStringRef)value, buf, sizeof(buf),
                            kCFStringEncodingUTF8)) {
        return false;
    }
    return strcmp(buf, expected) == 0;
}

static int cfnumber_to_int(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return -1;
    }
    int result = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    return result;
}

static bool runloop_wait(bool *done, double timeout_sec) {
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

// ============================================================
// Device discovery
// ============================================================

// Find changer via IOSCSIPeripheralDeviceNub (type 8)
static io_service_t find_scsi_changer(void) {
    io_iterator_t iter = IO_OBJECT_NULL;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (!match) return IO_OBJECT_NULL;

    kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                    match, &iter);
    if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_service_t result = IO_OBJECT_NULL;
    io_service_t service;

    while ((service = IOIteratorNext(iter))) {
        // Check Peripheral Device Type = 8 (media changer)
        CFTypeRef type_ref = IORegistryEntryCreateCFProperty(
            service, CFSTR("Peripheral Device Type"), kCFAllocatorDefault, 0);
        int dev_type = cfnumber_to_int(type_ref);
        if (type_ref) CFRelease(type_ref);

        if (dev_type == 8) {
            result = service;
            break;
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iter);
    return result;
}

// Find SCSITaskUserClient device for a given peripheral nub
static io_service_t find_scsi_task_device(io_service_t nub) {
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(nub, kIOServicePlane, &iter) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    io_service_t result = IO_OBJECT_NULL;
    io_service_t child;

    while ((child = IOIteratorNext(iter))) {
        CFTypeRef category = IORegistryEntryCreateCFProperty(
            child, CFSTR("SCSITaskDeviceCategory"), kCFAllocatorDefault, 0);
        if (category) {
            CFRelease(category);
            result = child;
            break;
        }
        IOObjectRelease(child);
    }

    IOObjectRelease(iter);
    return result;
}

// Fallback: find by vendor/product in the tree
static io_service_t find_scsi_task_global(const char *vendor, const char *product) {
    io_iterator_t iter = IO_OBJECT_NULL;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (!match) return IO_OBJECT_NULL;

    kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                    match, &iter);
    if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_service_t result = IO_OBJECT_NULL;
    io_service_t service;

    while ((service = IOIteratorNext(iter))) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(
            service, CFSTR("Vendor Identification"), kCFAllocatorDefault, 0);
        CFTypeRef p = IORegistryEntryCreateCFProperty(
            service, CFSTR("Product Identification"), kCFAllocatorDefault, 0);
        CFTypeRef cat = IORegistryEntryCreateCFProperty(
            service, CFSTR("SCSITaskDeviceCategory"), kCFAllocatorDefault, 0);

        bool v_ok = cfstring_equals(v, vendor);
        bool p_ok = cfstring_equals(p, product);
        bool cat_ok = cfstring_equals(cat, "SCSITaskUserClientDevice");

        if (v) CFRelease(v);
        if (p) CFRelease(p);
        if (cat) CFRelease(cat);

        if (v_ok && p_ok && cat_ok) {
            result = service;
            break;
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iter);
    return result;
}

io_service_t changer_find_service(void) {
    return find_scsi_changer();
}

// ============================================================
// SCSITask backend
// ============================================================

static int connect_scsitask(ChangerConnection *conn, io_service_t nub) {
    // Get vendor/product for fallback search
    char vendor[128] = {0};
    char product[128] = {0};

    CFTypeRef v = IORegistryEntryCreateCFProperty(
        nub, CFSTR("Vendor Identification"), kCFAllocatorDefault, 0);
    CFTypeRef p = IORegistryEntryCreateCFProperty(
        nub, CFSTR("Product Identification"), kCFAllocatorDefault, 0);

    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, vendor, sizeof(vendor), kCFStringEncodingUTF8);
    }
    if (p && CFGetTypeID(p) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)p, product, sizeof(product), kCFStringEncodingUTF8);
    }
    if (v) CFRelease(v);
    if (p) CFRelease(p);

    // Find SCSITask device
    io_service_t task_service = find_scsi_task_device(nub);
    if (task_service == IO_OBJECT_NULL && vendor[0] && product[0]) {
        task_service = find_scsi_task_global(vendor, product);
    }
    if (task_service == IO_OBJECT_NULL) {
        return -1;
    }

    // Create plugin interface
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        task_service,
        kIOSCSITaskDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    IOObjectRelease(task_service);

    if (kr != KERN_SUCCESS || !plugin) {
        return -1;
    }

    // Query for SCSITaskDevice interface
    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID),
        (LPVOID *)&conn->scsi_device
    );
    (*plugin)->Release(plugin);

    if (hr != S_OK || !conn->scsi_device) {
        return -1;
    }

    // Get exclusive access
    kr = (*conn->scsi_device)->ObtainExclusiveAccess(conn->scsi_device);
    if (kr == kIOReturnSuccess) {
        conn->has_exclusive = true;
    }

    conn->backend = BACKEND_SCSITASK;
    conn->connected = true;
    return 0;
}

static void disconnect_scsitask(ChangerConnection *conn) {
    if (conn->scsi_device) {
        if (conn->has_exclusive) {
            (*conn->scsi_device)->ReleaseExclusiveAccess(conn->scsi_device);
        }
        (*conn->scsi_device)->Release(conn->scsi_device);
        conn->scsi_device = NULL;
    }
}

static int execute_cdb_scsitask(ChangerConnection *conn,
                                const uint8_t *cdb, uint8_t cdb_len,
                                void *buffer, uint32_t buffer_len,
                                int direction, uint32_t timeout_ms) {
    SCSITaskInterface **task = (*conn->scsi_device)->CreateSCSITask(conn->scsi_device);
    if (!task) {
        fprintf(stderr, "CreateSCSITask failed\n");
        return -1;
    }

    (*task)->SetTaskAttribute(task, kSCSITask_SIMPLE);
    (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, cdb_len);
    (*task)->SetTimeoutDuration(task, timeout_ms);

    // Set up buffer
    uint8_t scsi_dir;
    if (direction == DIR_NONE) {
        scsi_dir = kSCSIDataTransfer_NoDataTransfer;
        (*task)->SetScatterGatherEntries(task, NULL, 0, 0, scsi_dir);
    } else {
        scsi_dir = (direction == DIR_READ) ?
                   kSCSIDataTransfer_FromTargetToInitiator :
                   kSCSIDataTransfer_FromInitiatorToTarget;
        SCSITaskSGElement sg;
#if defined(__LP64__)
        sg.address = (mach_vm_address_t)buffer;
        sg.length = buffer_len;
#else
        sg.address = (UInt32)buffer;
        sg.length = buffer_len;
#endif
        (*task)->SetScatterGatherEntries(task, &sg, 1, buffer_len, scsi_dir);
    }

    // Execute
    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status = 0;
    UInt64 transferred = 0;

    IOReturn kr = (*task)->ExecuteTaskSync(task, &sense, &status, &transferred);
    (*task)->Release(task);

    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "ExecuteTaskSync failed: 0x%x\n", kr);
        // Try to extract sense data anyway
        uint8_t sense_key = sense.SENSE_KEY & 0x0F;
        uint8_t asc = sense.ADDITIONAL_SENSE_CODE;
        uint8_t ascq = sense.ADDITIONAL_SENSE_CODE_QUALIFIER;
        if (sense_key != 0 || asc != 0 || ascq != 0) {
            scsi_set_sense(sense_key, asc, ascq);
        }
        return -1;
    }

    if (status != kSCSITaskStatus_GOOD) {
        // Store sense data for error reporting
        uint8_t sense_key = sense.SENSE_KEY & 0x0F;
        uint8_t asc = sense.ADDITIONAL_SENSE_CODE;
        uint8_t ascq = sense.ADDITIONAL_SENSE_CODE_QUALIFIER;
        scsi_set_sense(sense_key, asc, ascq);
        fprintf(stderr, "SCSI status: 0x%x, sense: %02x/%02x/%02x\n",
                status, sense_key, asc, ascq);
        return -1;
    }

    return 0;
}

// ============================================================
// SBP2 backend (fallback)
// ============================================================

typedef struct {
    bool done;
    IOReturn status;
} LoginWait;

typedef struct {
    bool done;
    UInt32 event;
} StatusWait;

static void login_callback(void *refCon, FWSBP2LoginCompleteParams *params) {
    LoginWait *wait = (LoginWait *)refCon;
    if (wait) {
        wait->status = params->status;
        wait->done = true;
    }
}

static void status_callback(void *refCon, FWSBP2NotifyParams *params) {
    StatusWait *wait = (StatusWait *)refCon;
    if (wait) {
        wait->event = params->notificationEvent;
        wait->done = true;
    }
}

static io_service_t find_sbp2_changer(void) {
    io_iterator_t iter = IO_OBJECT_NULL;
    CFMutableDictionaryRef match = IOServiceMatching("IOFireWireSBP2LUN");
    if (!match) return IO_OBJECT_NULL;

    kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                    match, &iter);
    if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_service_t result = IO_OBJECT_NULL;
    io_service_t service;

    while ((service = IOIteratorNext(iter))) {
        CFTypeRef type_ref = IORegistryEntryCreateCFProperty(
            service, CFSTR("Device_Type"), kCFAllocatorDefault, 0);
        int dev_type = cfnumber_to_int(type_ref);
        if (type_ref) CFRelease(type_ref);

        if (dev_type == 8) {
            result = service;
            break;
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iter);
    return result;
}

static int connect_sbp2(ChangerConnection *conn) {
    io_service_t service = find_sbp2_changer();
    if (service == IO_OBJECT_NULL) {
        return -1;
    }

    conn->service = service;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOFireWireSBP2LibTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );

    if (kr != KERN_SUCCESS || !plugin) {
        fprintf(stderr, "SBP2 plugin creation failed: 0x%x\n", kr);
        return -1;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOFireWireSBP2LibLUNInterfaceID),
        (LPVOID *)&conn->lun
    );
    (*plugin)->Release(plugin);

    if (hr != S_OK || !conn->lun) {
        return -1;
    }

    kr = (*conn->lun)->open(conn->lun);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "SBP2 LUN open failed: 0x%x\n", kr);
        (*conn->lun)->Release(conn->lun);
        conn->lun = NULL;
        return -1;
    }

    (*conn->lun)->addCallbackDispatcherToRunLoop(conn->lun, CFRunLoopGetCurrent());

    IUnknownVTbl **login_unknown = (*conn->lun)->createLogin(
        conn->lun,
        CFUUIDGetUUIDBytes(kIOFireWireSBP2LibLoginInterfaceID)
    );

    if (!login_unknown) {
        (*conn->lun)->close(conn->lun);
        (*conn->lun)->Release(conn->lun);
        conn->lun = NULL;
        return -1;
    }

    conn->login = (IOFireWireSBP2LibLoginInterface **)login_unknown;
    (*conn->login)->setLoginFlags(conn->login, kFWSBP2ExclusiveLogin);

    LoginWait wait = {0};
    (*conn->login)->setLoginCallback(conn->login, &wait, login_callback);

    kr = (*conn->login)->submitLogin(conn->login);
    if (kr != kIOReturnSuccess || !runloop_wait(&wait.done, 5.0) ||
        wait.status != kIOReturnSuccess) {
        (*conn->login)->Release(conn->login);
        (*conn->lun)->close(conn->lun);
        (*conn->lun)->Release(conn->lun);
        conn->login = NULL;
        conn->lun = NULL;
        return -1;
    }

    conn->backend = BACKEND_SBP2;
    conn->connected = true;
    return 0;
}

static void disconnect_sbp2(ChangerConnection *conn) {
    if (conn->login) {
        (*conn->login)->submitLogout(conn->login);
        (*conn->login)->Release(conn->login);
        conn->login = NULL;
    }
    if (conn->lun) {
        (*conn->lun)->removeCallbackDispatcherFromRunLoop(conn->lun);
        (*conn->lun)->close(conn->lun);
        (*conn->lun)->Release(conn->lun);
        conn->lun = NULL;
    }
}

static int execute_cdb_sbp2(ChangerConnection *conn,
                            const uint8_t *cdb, uint8_t cdb_len,
                            void *buffer, uint32_t buffer_len,
                            int direction, uint32_t timeout_ms) {
    IUnknownVTbl **orb_unknown = (*conn->login)->createORB(
        conn->login,
        CFUUIDGetUUIDBytes(kIOFireWireSBP2LibORBInterfaceID)
    );

    if (!orb_unknown) {
        return -1;
    }

    IOFireWireSBP2LibORBInterface **orb =
        (IOFireWireSBP2LibORBInterface **)orb_unknown;

    StatusWait wait = {0};
    (*orb)->setRefCon(orb, &wait);
    (*conn->login)->setStatusNotify(conn->login, &wait, status_callback);

    UInt32 flags = kFWSBP2CommandCompleteNotify | kFWSBP2CommandNormalORB;
    if (direction == DIR_READ) {
        flags |= kFWSBP2CommandTransferDataFromTarget;
    }
    (*orb)->setCommandFlags(orb, flags);
    (*orb)->setCommandTimeout(orb, timeout_ms);
    (*orb)->setCommandBlock(orb, (void *)cdb, cdb_len);

    if (direction != DIR_NONE && buffer && buffer_len > 0) {
        FWSBP2VirtualRange range;
        range.address = buffer;
        range.length = buffer_len;
        UInt32 io_dir = (direction == DIR_READ) ? kIODirectionIn : kIODirectionOut;
        (*orb)->setCommandBuffersAsRanges(orb, &range, 1, io_dir, 0, buffer_len);
    }

    IOReturn kr = (*conn->login)->submitORB(conn->login, orb);
    if (kr != kIOReturnSuccess) {
        (*orb)->Release(orb);
        return -1;
    }

    (*conn->login)->ringDoorbell(conn->login);

    if (!runloop_wait(&wait.done, (double)timeout_ms / 1000.0 + 1.0)) {
        (*orb)->Release(orb);
        return -1;
    }

    if (direction != DIR_NONE && buffer && buffer_len > 0) {
        (*orb)->releaseCommandBuffers(orb);
    }

    (*orb)->Release(orb);

    if (wait.event != kFWSBP2NormalCommandStatus) {
        return -1;
    }

    return 0;
}

// ============================================================
// Public API
// ============================================================

int changer_connect(ChangerConnection *conn) {
    if (!conn) return -1;
    memset(conn, 0, sizeof(*conn));

    // Try SCSITask first (goes through kernel driver)
    io_service_t nub = find_scsi_changer();
    if (nub != IO_OBJECT_NULL) {
        conn->service = nub;
        if (connect_scsitask(conn, nub) == 0) {
            return 0;
        }
        // SCSITask failed, keep service for info
    }

    // Fallback to direct SBP2 (may fail if kernel has device)
    if (connect_sbp2(conn) == 0) {
        return 0;
    }

    return -1;
}

void changer_disconnect(ChangerConnection *conn) {
    if (!conn) return;

    if (conn->backend == BACKEND_SCSITASK) {
        disconnect_scsitask(conn);
    } else if (conn->backend == BACKEND_SBP2) {
        disconnect_sbp2(conn);
    }

    if (conn->service) {
        IOObjectRelease(conn->service);
        conn->service = IO_OBJECT_NULL;
    }

    conn->connected = false;
}

int changer_execute_cdb(ChangerConnection *conn,
                        const uint8_t *cdb, uint8_t cdb_len,
                        void *buffer, uint32_t buffer_len,
                        int direction, uint32_t timeout_ms) {
    if (!conn || !conn->connected) return -1;

    if (conn->backend == BACKEND_SCSITASK) {
        return execute_cdb_scsitask(conn, cdb, cdb_len, buffer, buffer_len,
                                    direction, timeout_ms);
    } else if (conn->backend == BACKEND_SBP2) {
        return execute_cdb_sbp2(conn, cdb, cdb_len, buffer, buffer_len,
                                direction, timeout_ms);
    }

    return -1;
}
