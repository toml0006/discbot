#ifndef SBP2_H
#define SBP2_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/sbp2/IOFireWireSBP2Lib.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <stdbool.h>
#include <stdint.h>

// Backend type
typedef enum {
    BACKEND_NONE = 0,
    BACKEND_SCSITASK,
    BACKEND_SBP2
} BackendType;

// Connection handle for changer device
typedef struct {
    BackendType backend;
    io_service_t service;
    // SCSITask backend
    SCSITaskDeviceInterface **scsi_device;
    bool has_exclusive;
    // SBP2 backend
    IOFireWireSBP2LibLUNInterface **lun;
    IOFireWireSBP2LibLoginInterface **login;
    bool connected;
} ChangerConnection;

// Find changer via SCSI (preferred) or SBP2 fallback
io_service_t changer_find_service(void);

// Connect to changer device (tries SCSITask first, then SBP2)
int changer_connect(ChangerConnection *conn);

// Disconnect from changer
void changer_disconnect(ChangerConnection *conn);

// Execute a SCSI CDB
// direction: 0 = no data, 1 = read (from device), 2 = write (to device)
int changer_execute_cdb(ChangerConnection *conn,
                        const uint8_t *cdb, uint8_t cdb_len,
                        void *buffer, uint32_t buffer_len,
                        int direction, uint32_t timeout_ms);

// Direction constants
#define DIR_NONE  0
#define DIR_READ  1
#define DIR_WRITE 2

#endif // SBP2_H
