#ifndef MOUNT_H
#define MOUNT_H

#include <stdbool.h>

// Find the BSD name of the DVD drive (e.g., "disk2")
// Returns malloc'd string or NULL if not found
char *mount_find_dvd_bsd_name(void);

// Wait for disc to be ready after loading
// Returns 0 on success, -1 on timeout
int mount_wait_for_disc(int timeout_seconds);

// Check if the drive currently has a disc
bool mount_is_disc_present(void);

// Mount the disc
// Returns malloc'd mount point path on success, NULL on failure
char *mount_disc(const char *bsd_name, int timeout_seconds);

// Unmount the disc
// Returns 0 on success, error code on failure
int mount_unmount_disc(const char *bsd_name, bool force);

// Check if BSD device is currently mounted
bool mount_is_mounted(const char *bsd_name);

// Get mount point for BSD device
// Returns malloc'd path or NULL if not mounted
char *mount_get_mount_point(const char *bsd_name);

// Get volume name for BSD device
// Returns malloc'd name or NULL if not available
char *mount_get_volume_name(const char *bsd_name);

// Eject the disc (unmount and release from drive)
// This makes the disc available for the changer to grab
// Returns 0 on success, error code on failure
int mount_eject_disc(const char *bsd_name, bool force);

#endif // MOUNT_H
