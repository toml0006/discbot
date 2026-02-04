#include "scsi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Last sense data from failed command
static SenseData g_last_sense = {0};

SenseData scsi_get_last_sense(void) {
    return g_last_sense;
}

void scsi_set_sense(uint8_t sense_key, uint8_t asc, uint8_t ascq) {
    g_last_sense.sense_key = sense_key;
    g_last_sense.asc = asc;
    g_last_sense.ascq = ascq;
    g_last_sense.valid = true;
}

const char *scsi_sense_string(SenseData *sense) {
    if (!sense || !sense->valid) {
        return "No sense data";
    }

    // Common sense key/ASC/ASCQ combinations for media changers
    switch (sense->sense_key) {
    case 0x00:
        return "No sense";
    case 0x02: // NOT READY
        if (sense->asc == 0x04) {
            if (sense->ascq == 0x00) return "Not ready, cause not reportable";
            if (sense->ascq == 0x01) return "Becoming ready";
            if (sense->ascq == 0x02) return "Need INITIALIZE ELEMENT STATUS";
            if (sense->ascq == 0x03) return "Manual intervention required";
        }
        if (sense->asc == 0x3A) return "Medium not present";
        return "Not ready";
    case 0x05: // ILLEGAL REQUEST
        if (sense->asc == 0x21) return "Invalid element address";
        if (sense->asc == 0x24) return "Invalid field in CDB";
        if (sense->asc == 0x3B) {
            if (sense->ascq == 0x0D) return "Medium destination full";
            if (sense->ascq == 0x0E) return "Medium source empty";
            return "Element position error";
        }
        return "Illegal request";
    case 0x06: // UNIT ATTENTION
        if (sense->asc == 0x28) return "Medium may have changed";
        if (sense->asc == 0x29) return "Power on or reset";
        return "Unit attention";
    case 0x0B: // ABORTED COMMAND
        if (sense->asc == 0x3B) {
            if (sense->ascq == 0x0D) return "Medium destination full";
            if (sense->ascq == 0x0E) return "Medium source empty";
            return "Element position error";
        }
        return "Aborted command";
    default:
        return "Unknown error";
    }
}

// Parse sense data from response (simplified - assumes fixed format)
static void parse_sense(const uint8_t *sense_buf, size_t len) {
    g_last_sense.valid = false;
    if (!sense_buf || len < 8) return;

    uint8_t response_code = sense_buf[0] & 0x7F;
    if (response_code != 0x70 && response_code != 0x71) {
        // Not fixed format sense
        return;
    }

    g_last_sense.sense_key = sense_buf[2] & 0x0F;
    if (len >= 13) {
        g_last_sense.asc = sense_buf[12];
    }
    if (len >= 14) {
        g_last_sense.ascq = sense_buf[13];
    }
    g_last_sense.valid = true;
}

int scsi_test_unit_ready(ChangerConnection *conn) {
    uint8_t cdb[6] = {0};
    cdb[0] = 0x00; // TEST UNIT READY

    return changer_execute_cdb(conn, cdb, 6, NULL, 0, DIR_NONE, 10000);
}

int scsi_inquiry(ChangerConnection *conn, DeviceInfo *info) {
    uint8_t cdb[6] = {0};
    cdb[0] = 0x12; // INQUIRY
    cdb[4] = 96;   // Allocation length

    uint8_t buf[96] = {0};
    int rc = changer_execute_cdb(conn, cdb, 6, buf, 96, DIR_READ, 10000);

    if (rc == 0 && info) {
        info->device_type = buf[0] & 0x1F;
        memcpy(info->vendor, &buf[8], 8);
        info->vendor[8] = '\0';
        memcpy(info->product, &buf[16], 16);
        info->product[16] = '\0';
        memcpy(info->revision, &buf[32], 4);
        info->revision[4] = '\0';

        // Trim trailing spaces
        for (int i = 7; i >= 0 && info->vendor[i] == ' '; i--) {
            info->vendor[i] = '\0';
        }
        for (int i = 15; i >= 0 && info->product[i] == ' '; i--) {
            info->product[i] = '\0';
        }
        for (int i = 3; i >= 0 && info->revision[i] == ' '; i--) {
            info->revision[i] = '\0';
        }
    }

    return rc;
}

int scsi_mode_sense_element(ChangerConnection *conn, ElementMap *map) {
    if (!conn || !map) return -1;

    // Send TEST UNIT READY to clear any UNIT ATTENTION condition
    for (int i = 0; i < 3; i++) {
        if (scsi_test_unit_ready(conn) == 0) break;
        // Small delay between retries
        usleep(100000); // 100ms
    }

    uint8_t cdb[10] = {0};
    cdb[0] = 0x5A; // MODE SENSE(10)
    cdb[1] = 0x08; // DBD=1 (disable block descriptors)
    cdb[2] = 0x1D; // Element Address Assignment page
    uint16_t alloc = 256;
    cdb[7] = (alloc >> 8) & 0xFF;
    cdb[8] = alloc & 0xFF;

    uint8_t buf[256] = {0};
    int rc = changer_execute_cdb(conn, cdb, 10, buf, alloc, DIR_READ, 10000);
    if (rc != 0) return rc;

    // Parse mode page header
    uint16_t block_desc_len = (buf[6] << 8) | buf[7];
    uint32_t page_offset = 8 + block_desc_len;

    if (page_offset + 18 > alloc) {
        fprintf(stderr, "Mode page too short\n");
        return -1;
    }

    uint8_t page_code = buf[page_offset] & 0x3F;
    uint8_t page_len = buf[page_offset + 1];

    if (page_code != 0x1D || page_len < 16) {
        fprintf(stderr, "Unexpected mode page 0x%02x len %u\n",
                page_code, page_len);
        return -1;
    }

    // Parse element address assignment
    const uint8_t *p = &buf[page_offset + 2];

    map->transport = (p[0] << 8) | p[1];
    uint16_t num_transport = (p[2] << 8) | p[3];
    (void)num_transport; // Usually 1

    uint16_t first_storage = (p[4] << 8) | p[5];
    uint16_t num_storage = (p[6] << 8) | p[7];

    uint16_t first_ie = (p[8] << 8) | p[9];
    uint16_t num_ie = (p[10] << 8) | p[11];

    map->drive = (p[12] << 8) | p[13];
    // uint16_t num_drive = (p[14] << 8) | p[15]; // Usually 1

    // Allocate slot array
    if (num_storage > 0) {
        map->slots = calloc(num_storage, sizeof(uint16_t));
        if (!map->slots) {
            return -1;
        }
        map->slot_count = num_storage;
        for (uint16_t i = 0; i < num_storage; i++) {
            map->slots[i] = first_storage + i;
        }
    }

    // IE element
    if (num_ie > 0) {
        map->ie = first_ie;
        map->has_ie = true;
    }

    return 0;
}

int scsi_read_element_status(ChangerConnection *conn,
                             uint8_t element_type,
                             uint16_t start, uint16_t count,
                             ElementStatus *statuses,
                             size_t max_statuses) {
    if (!conn) return -1;

    // Calculate buffer size - estimate ~24 bytes per element + headers
    uint32_t alloc = 8 + 8 + (count * 24);
    if (alloc < 4096) alloc = 4096;
    if (alloc > 65535) alloc = 65535;

    uint8_t *buf = calloc(1, alloc);
    if (!buf) return -1;

    uint8_t cdb[12] = {0};
    cdb[0] = 0xB8; // READ ELEMENT STATUS
    cdb[1] = element_type & 0x0F;
    cdb[2] = (start >> 8) & 0xFF;
    cdb[3] = start & 0xFF;
    cdb[4] = (count >> 8) & 0xFF;
    cdb[5] = count & 0xFF;
    cdb[6] = (alloc >> 16) & 0xFF;
    cdb[7] = (alloc >> 8) & 0xFF;
    cdb[8] = alloc & 0xFF;

    int rc = changer_execute_cdb(conn, cdb, 12, buf, alloc, DIR_READ, 30000);
    if (rc != 0) {
        fprintf(stderr, "READ ELEMENT STATUS: command failed rc=%d\n", rc);
        free(buf);
        return rc;
    }

    // Parse response header
    uint16_t first_elem = (buf[0] << 8) | buf[1];
    uint16_t num_elem = (buf[2] << 8) | buf[3];
    uint32_t report_bytes = (buf[5] << 16) | (buf[6] << 8) | buf[7];

    fprintf(stderr, "READ ELEMENT STATUS type=%d start=%u count=%u: first=%u num=%u report_bytes=%u\n",
            element_type, start, count, first_elem, num_elem, report_bytes);

    if (report_bytes == 0) {
        fprintf(stderr, "READ ELEMENT STATUS: no data returned\n");
        free(buf);
        return 0;
    }

    // Parse element status pages
    if (!statuses) {
        free(buf);
        return 0; // Just checking if command works
    }

    size_t status_idx = 0;
    uint32_t offset = 8;
    uint32_t end = 8 + report_bytes;
    if (end > alloc) end = alloc;

    while (offset + 8 <= end && status_idx < max_statuses) {
        // Element type header
        uint8_t type = buf[offset] & 0x0F;
        uint16_t desc_len = (buf[offset + 2] << 8) | buf[offset + 3];
        uint32_t page_bytes = (buf[offset + 5] << 16) |
                              (buf[offset + 6] << 8) | buf[offset + 7];

        fprintf(stderr, "  Page header: type=%d desc_len=%u page_bytes=%u\n",
                type, desc_len, page_bytes);

        offset += 8;

        if (desc_len == 0 || page_bytes == 0) {
            fprintf(stderr, "  Page has zero desc_len or page_bytes, stopping\n");
            break;
        }

        uint32_t page_end = offset + page_bytes;
        if (page_end > end) page_end = end;

        // Parse element descriptors
        while (offset + desc_len <= page_end && status_idx < max_statuses) {
            if (desc_len < 2) {
                offset = page_end;
                break;
            }

            uint16_t addr = (buf[offset] << 8) | buf[offset + 1];
            uint8_t flags = buf[offset + 2];

            // Skip all-zero entries (padding)
            bool all_zero = true;
            for (uint16_t i = 0; i < desc_len && i < 12; i++) {
                if (buf[offset + i] != 0) {
                    all_zero = false;
                    break;
                }
            }

            if (!all_zero || type != ELEM_STORAGE) {
                statuses[status_idx].address = addr;
                statuses[status_idx].full = (flags & 0x01) != 0;
                statuses[status_idx].except = (flags & 0x04) != 0;

                // Source address (if available)
                if (desc_len >= 12) {
                    statuses[status_idx].source_valid =
                        (buf[offset + 9] & 0x80) != 0;
                    statuses[status_idx].source =
                        (buf[offset + 10] << 8) | buf[offset + 11];
                }

                fprintf(stderr, "  Element: addr=%u full=%d except=%d src_valid=%d src=%u\n",
                        addr, statuses[status_idx].full, statuses[status_idx].except,
                        statuses[status_idx].source_valid, statuses[status_idx].source);

                status_idx++;
            } else {
                fprintf(stderr, "  Element: addr=%u skipped (all-zero storage)\n", addr);
            }

            offset += desc_len;
        }

        if (offset < page_end) offset = page_end;
    }

    free(buf);
    return (int)status_idx;
}

int scsi_move_medium(ChangerConnection *conn,
                     uint16_t transport,
                     uint16_t source,
                     uint16_t dest) {
    uint8_t cdb[12] = {0};
    cdb[0] = 0xA5; // MOVE MEDIUM
    cdb[2] = (transport >> 8) & 0xFF;
    cdb[3] = transport & 0xFF;
    cdb[4] = (source >> 8) & 0xFF;
    cdb[5] = source & 0xFF;
    cdb[6] = (dest >> 8) & 0xFF;
    cdb[7] = dest & 0xFF;

    return changer_execute_cdb(conn, cdb, 12, NULL, 0, DIR_NONE, 120000);
}

int scsi_init_element_status(ChangerConnection *conn) {
    uint8_t cdb[6] = {0};
    cdb[0] = 0x07; // INITIALIZE ELEMENT STATUS

    return changer_execute_cdb(conn, cdb, 6, NULL, 0, DIR_NONE, 120000);
}

void element_map_free(ElementMap *map) {
    if (!map) return;
    free(map->slots);
    map->slots = NULL;
    map->slot_count = 0;
}
