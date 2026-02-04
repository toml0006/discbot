#ifndef SCSI_H
#define SCSI_H

#include "sbp2.h"
#include <stdint.h>
#include <stdbool.h>

// Element types
#define ELEM_TRANSPORT 0x01
#define ELEM_STORAGE   0x02
#define ELEM_IE        0x03
#define ELEM_DRIVE     0x04
#define ELEM_ALL       0x00

// Element map - addresses for all element types
typedef struct {
    uint16_t transport;      // Robot arm address
    uint16_t *slots;         // Array of slot addresses
    size_t slot_count;
    uint16_t drive;          // Drive address
    uint16_t ie;             // Import/export address (if any)
    bool has_ie;
} ElementMap;

// Status of a single element
typedef struct {
    uint16_t address;
    bool full;               // Has media
    bool except;             // Exception condition
    uint16_t source;         // Source address (if valid)
    bool source_valid;
} ElementStatus;

// Device info from INQUIRY
typedef struct {
    char vendor[9];
    char product[17];
    char revision[5];
    uint8_t device_type;
} DeviceInfo;

// SCSI sense data
typedef struct {
    uint8_t sense_key;
    uint8_t asc;
    uint8_t ascq;
    bool valid;
} SenseData;

// Get last sense data from failed command
SenseData scsi_get_last_sense(void);

// Set sense data (called from sbp2.c on command failure)
void scsi_set_sense(uint8_t sense_key, uint8_t asc, uint8_t ascq);

// Interpret sense data as human-readable string
const char *scsi_sense_string(SenseData *sense);

// TEST UNIT READY - check device is ready
int scsi_test_unit_ready(ChangerConnection *conn);

// INQUIRY - get device identification
int scsi_inquiry(ChangerConnection *conn, DeviceInfo *info);

// MODE SENSE - get element address assignment
int scsi_mode_sense_element(ChangerConnection *conn, ElementMap *map);

// READ ELEMENT STATUS - get status of elements
// If statuses is NULL, just returns count
int scsi_read_element_status(ChangerConnection *conn,
                             uint8_t element_type,
                             uint16_t start, uint16_t count,
                             ElementStatus *statuses,
                             size_t max_statuses);

// MOVE MEDIUM - move media between elements
int scsi_move_medium(ChangerConnection *conn,
                     uint16_t transport,
                     uint16_t source,
                     uint16_t dest);

// INITIALIZE ELEMENT STATUS - rescan all elements
int scsi_init_element_status(ChangerConnection *conn);

// Free element map resources
void element_map_free(ElementMap *map);

#endif // SCSI_H
