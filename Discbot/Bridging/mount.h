/*
 * mount.h - Disc mounting utilities for DiskArbitration
 */

#ifndef MOUNT_H
#define MOUNT_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Wait for a disc to appear (timeout in seconds). Returns 0 on success. */
int mount_wait_for_disc(int timeout);

/* Find the BSD name of a DVD/CD disc. Caller must free() the result. */
char *mount_find_dvd_bsd_name(void);

/* Check if a disc is present in any optical drive */
bool mount_is_disc_present(void);

/* Mount a disc by BSD name. Returns mount point (caller must free) or NULL. */
char *mount_disc(const char *bsd_name, int timeout);

/* Unmount a disc by BSD name. Returns 0 on success. */
int mount_unmount_disc(const char *bsd_name, bool force);

/* Eject a disc by BSD name (unmount + release from drive). Returns 0 on success. */
int mount_eject_disc(const char *bsd_name, bool force);

/* Check if a BSD device is currently mounted */
bool mount_is_mounted(const char *bsd_name);

/* Get the mount point for a BSD name. Caller must free() the result. */
char *mount_get_mount_point(const char *bsd_name);

/* Get the volume name for a BSD name. Caller must free() the result. */
char *mount_get_volume_name(const char *bsd_name);

#ifdef __cplusplus
}
#endif

#endif /* MOUNT_H */
