/*
 * CDReader.c - Raw CD sector access through IOCDMediaBSDClient
 */

#include "CDReader.h"

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOCDMedia.h>
#include <IOKit/storage/IOCDMediaBSDClient.h>
#include <IOKit/storage/IOCDTypes.h>
#include <IOKit/storage/IOMedia.h>
#include <libkern/OSByteOrder.h>

typedef struct {
    uint8_t number;
    uint8_t session;
    uint8_t control;
    uint32_t start_lba;
} DiscBotCDTrack;

struct DiscBotCDReader {
    int descriptor;
    char raw_path[256];
    uint32_t track_count;
    uint32_t leadout_lba;
    DiscBotCDTrack tracks[DISCBOT_CD_MAX_TRACKS];
};

static void set_error(char *buffer, size_t length, const char *format, ...);
static void describe_groups(char *buffer, size_t length);
static int process_has_group(gid_t expected);

/*
 * Reading the published TOC is safe while cddafs owns the disc, but opening
 * the raw BSD device on the Sony FireWire bridge can block in the kernel.
 * Keep layout-only operations (identity and media-type detection) completely
 * separate from raw sector access and open the descriptor only on first read.
 */
static int ensure_descriptor(
    DiscBotCDReader *reader,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (reader->descriptor >= 0) return 0;

    int open_errno = 0;
    for (int attempt = 0; attempt < 40; attempt++) {
        reader->descriptor = open(reader->raw_path, O_RDONLY | O_NONBLOCK);
        if (reader->descriptor >= 0) return 0;
        open_errno = errno;
        if (open_errno != EACCES && open_errno != EPERM &&
            open_errno != EBUSY && open_errno != ENOENT) {
            break;
        }
        usleep(250000);
    }

    if (open_errno == EACCES || open_errno == EPERM) {
        struct passwd *account = getpwuid(getuid());
        const char *user_name = account != NULL && account->pw_name != NULL
            ? account->pw_name : "CURRENT_USER";
        char groups[256];
        describe_groups(groups, sizeof(groups));
        struct stat device_status;
        int stat_result = stat(reader->raw_path, &device_status);
        const char *details_format =
            "Raw CD access denied for %s after 10 seconds "
            "(uid=%u euid=%u gid=%u egid=%u groups=%s device=%s%o:%u:%u). %s";
        char remedy[384];
        if (process_has_group(5)) {
            snprintf(
                remedy,
                sizeof(remedy),
                "The operator permission is present; Catalina System Policy is blocking raw-disk access. Grant Full Disk Access to Discbot-Server.app, then restart Discbot."
            );
        } else {
            snprintf(
                remedy,
                sizeof(remedy),
                "Run `sudo dseditgroup -o edit -a %s -t user operator`, then restart Discbot.",
                user_name
            );
        }
        set_error(error_buffer, error_buffer_length, details_format,
                  reader->raw_path, (unsigned)getuid(), (unsigned)geteuid(),
                  (unsigned)getgid(), (unsigned)getegid(),
                  groups[0] == '\0' ? "none" : groups,
                  stat_result == 0 ? "" : "unavailable/",
                  stat_result == 0 ? (unsigned)(device_status.st_mode & 07777) : 0,
                  stat_result == 0 ? (unsigned)device_status.st_uid : 0,
                  stat_result == 0 ? (unsigned)device_status.st_gid : 0,
                  remedy);
    } else {
        set_error(error_buffer, error_buffer_length,
                  "Could not open %s: %s", reader->raw_path, strerror(open_errno));
    }
    return -1;
}

static void set_error(char *buffer, size_t length, const char *format, ...) {
    if (buffer == NULL || length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(buffer, length, format, arguments);
    va_end(arguments);
}

static void describe_groups(char *buffer, size_t length) {
    if (buffer == NULL || length == 0) return;
    buffer[0] = '\0';
    gid_t groups[32];
    int count = getgroups((int)(sizeof(groups) / sizeof(groups[0])), groups);
    if (count < 0) return;
    size_t used = 0;
    for (int index = 0; index < count && used < length; index++) {
        int written = snprintf(buffer + used, length - used, "%s%u",
                               index == 0 ? "" : ",", (unsigned)groups[index]);
        if (written < 0 || (size_t)written >= length - used) break;
        used += (size_t)written;
    }
}

static int process_has_group(gid_t expected) {
    if (getegid() == expected || getgid() == expected) return 1;
    gid_t groups[32];
    int count = getgroups((int)(sizeof(groups) / sizeof(groups[0])), groups);
    for (int index = 0; index < count; index++) {
        if (groups[index] == expected) return 1;
    }
    return 0;
}

static uint32_t clipped_lba(CDMSF value) {
    if (value.minute == 0 && value.second <= 1) return 0;
    return CDConvertMSFToLBA(value);
}

static int compare_tracks(const void *left, const void *right) {
    const DiscBotCDTrack *a = left;
    const DiscBotCDTrack *b = right;
    if (a->start_lba < b->start_lba) return -1;
    if (a->start_lba > b->start_lba) return 1;
    return (int)a->number - (int)b->number;
}

static int parse_toc(
    DiscBotCDReader *reader,
    const uint8_t *toc_storage,
    size_t toc_storage_length,
    char *error_buffer,
    size_t error_buffer_length
) {
    reader->track_count = 0;
    reader->leadout_lba = 0;
    if (toc_storage_length < sizeof(CDTOC)) {
        set_error(error_buffer, error_buffer_length, "The drive returned an incomplete CD table of contents");
        return -1;
    }

    const CDTOC *toc = (const CDTOC *)toc_storage;
    uint32_t declared_size = OSSwapBigToHostInt16(toc->length) + sizeof(toc->length);
    uint32_t toc_size = declared_size < toc_storage_length ? declared_size : (uint32_t)toc_storage_length;
    if (toc_size < sizeof(CDTOC)) {
        set_error(error_buffer, error_buffer_length, "The CD table of contents is invalid");
        return -1;
    }

    uint32_t descriptor_count = (toc_size - sizeof(CDTOC)) / sizeof(CDTOCDescriptor);
    for (uint32_t index = 0; index < descriptor_count; index++) {
        CDTOCDescriptor descriptor = toc->descriptors[index];
        if (descriptor.adr != 1) continue;

        uint32_t lba = clipped_lba(descriptor.p);
        if (descriptor.point >= 1 && descriptor.point <= 99) {
            if (reader->track_count >= DISCBOT_CD_MAX_TRACKS) break;
            DiscBotCDTrack *track = &reader->tracks[reader->track_count++];
            track->number = descriptor.point;
            track->session = descriptor.session;
            track->control = descriptor.control;
            track->start_lba = lba;
        } else if (descriptor.point == 0xA2 && lba > reader->leadout_lba) {
            reader->leadout_lba = lba;
        }
    }

    if (reader->track_count == 0) {
        set_error(error_buffer, error_buffer_length, "No tracks were found in the CD table of contents");
        return -1;
    }

    qsort(reader->tracks, reader->track_count, sizeof(DiscBotCDTrack), compare_tracks);
    if (reader->leadout_lba <= reader->tracks[reader->track_count - 1].start_lba) {
        set_error(error_buffer, error_buffer_length, "The CD lead-out address is missing or invalid");
        return -1;
    }
    return 0;
}

/*
 * IOCDMedia publishes its TOC as registry data when media is recognized.
 * Apple's Catalina cddafs implementation consumes this property rather than
 * issuing DKIOCCDREADTOC from user space.  On the Sony FireWire bridge the
 * ioctl can remain blocked in the kernel even though the property is already
 * available, so use the same non-blocking source as cddafs.
 */
static int read_published_toc(
    DiscBotCDReader *reader,
    const char *bsd_name,
    char *error_buffer,
    size_t error_buffer_length
) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOBSDNameMatching(
        kIOMasterPortDefault, 0, bsd_name);
    if (matching == NULL || IOServiceGetMatchingServices(
            kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS) {
        set_error(error_buffer, error_buffer_length,
                  "Could not locate IOCDMedia for %s", bsd_name);
        return -1;
    }

    io_registry_entry_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (service == IO_OBJECT_NULL ||
        !IOObjectConformsTo(service, kIOCDMediaClass)) {
        if (service != IO_OBJECT_NULL) IOObjectRelease(service);
        set_error(error_buffer, error_buffer_length,
                  "%s is not a recognized audio CD", bsd_name);
        return -1;
    }

    CFTypeRef property = IORegistryEntryCreateCFProperty(
        service, CFSTR("TOC"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (property == NULL || CFGetTypeID(property) != CFDataGetTypeID()) {
        if (property != NULL) CFRelease(property);
        set_error(error_buffer, error_buffer_length,
                  "The CD table of contents is not available for %s", bsd_name);
        return -1;
    }

    CFDataRef data = (CFDataRef)property;
    CFIndex length = CFDataGetLength(data);
    int result = length > 0
        ? parse_toc(reader, CFDataGetBytePtr(data), (size_t)length,
                    error_buffer, error_buffer_length)
        : -1;
    if (length <= 0) {
        set_error(error_buffer, error_buffer_length,
                  "The CD table of contents is empty for %s", bsd_name);
    }
    CFRelease(property);
    return result;
}

DiscBotCDReader *discbot_cd_reader_open(
    const char *bsd_name,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (bsd_name == NULL || bsd_name[0] == '\0') {
        set_error(error_buffer, error_buffer_length, "Missing CD device name");
        return NULL;
    }

    DiscBotCDReader *reader = calloc(1, sizeof(DiscBotCDReader));
    if (reader == NULL) {
        set_error(error_buffer, error_buffer_length, "Could not allocate the CD reader");
        return NULL;
    }
    reader->descriptor = -1;
    snprintf(reader->raw_path, sizeof(reader->raw_path), "/dev/r%s", bsd_name);
    if (read_published_toc(
            reader, bsd_name, error_buffer, error_buffer_length) != 0) {
        free(reader);
        return NULL;
    }

    return reader;
}

void discbot_cd_reader_close(DiscBotCDReader *reader) {
    if (reader == NULL) return;
    if (reader->descriptor >= 0) close(reader->descriptor);
    free(reader);
}

uint32_t discbot_cd_reader_track_count(const DiscBotCDReader *reader) {
    return reader == NULL ? 0 : reader->track_count;
}

uint8_t discbot_cd_reader_track_number(const DiscBotCDReader *reader, uint32_t index) {
    return reader == NULL || index >= reader->track_count ? 0 : reader->tracks[index].number;
}

uint8_t discbot_cd_reader_track_session(const DiscBotCDReader *reader, uint32_t index) {
    return reader == NULL || index >= reader->track_count ? 0 : reader->tracks[index].session;
}

uint8_t discbot_cd_reader_track_control(const DiscBotCDReader *reader, uint32_t index) {
    return reader == NULL || index >= reader->track_count ? 0 : reader->tracks[index].control;
}

uint32_t discbot_cd_reader_track_start_lba(const DiscBotCDReader *reader, uint32_t index) {
    return reader == NULL || index >= reader->track_count ? 0 : reader->tracks[index].start_lba;
}

uint32_t discbot_cd_reader_leadout_lba(const DiscBotCDReader *reader) {
    return reader == NULL ? 0 : reader->leadout_lba;
}

int discbot_cd_reader_read(
    DiscBotCDReader *reader,
    uint32_t start_lba,
    uint32_t sector_count,
    void *destination,
    uint32_t *sectors_read,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (sectors_read != NULL) *sectors_read = 0;
    if (reader == NULL || destination == NULL || sector_count == 0) {
        set_error(error_buffer, error_buffer_length, "Invalid raw CD read request");
        return -1;
    }
    if (sector_count > UINT32_MAX / DISCBOT_CD_SECTOR_SIZE) {
        set_error(error_buffer, error_buffer_length, "Raw CD read request is too large");
        return -1;
    }
    if (ensure_descriptor(reader, error_buffer, error_buffer_length) != 0) {
        return -1;
    }

    uint32_t requested_length = sector_count * DISCBOT_CD_SECTOR_SIZE;
    int saved_error = EIO;
    for (int attempt = 0; attempt < 5; attempt++) {
        dk_cd_read_t request;
        memset(&request, 0, sizeof(request));
        request.offset = (uint64_t)start_lba * DISCBOT_CD_SECTOR_SIZE;
        request.sectorArea = 0xF8; /* complete 2352-byte sector for every track type */
        request.sectorType = kCDSectorTypeUnknown;
        request.bufferLength = requested_length;
        request.buffer = destination;

        if (ioctl(reader->descriptor, DKIOCCDREAD, &request) == 0) {
            if (request.bufferLength % DISCBOT_CD_SECTOR_SIZE != 0) {
                set_error(error_buffer, error_buffer_length, "The drive returned a partial raw CD sector");
                return -1;
            }
            uint32_t completed = request.bufferLength / DISCBOT_CD_SECTOR_SIZE;
            if (sectors_read != NULL) *sectors_read = completed;
            if (completed > 0) return 0;
            saved_error = EIO;
        } else {
            saved_error = errno;
        }
        usleep((useconds_t)(50000 * (attempt + 1)));
    }

    set_error(
        error_buffer,
        error_buffer_length,
        "Could not read raw CD sector %u after five attempts: %s",
        start_lba,
        strerror(saved_error)
    );
    return -1;
}
