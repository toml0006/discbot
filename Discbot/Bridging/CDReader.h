/*
 * CDReader.h - Raw CD sector access through IOCDMediaBSDClient
 */

#ifndef DISCBOT_CD_READER_H
#define DISCBOT_CD_READER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DISCBOT_CD_SECTOR_SIZE 2352
#define DISCBOT_CD_MAX_TRACKS 99

typedef struct DiscBotCDReader DiscBotCDReader;

/* Opens the whole CD media device and reads its full TOC. */
DiscBotCDReader *discbot_cd_reader_open(
    const char *bsd_name,
    char *error_buffer,
    size_t error_buffer_length
);

void discbot_cd_reader_close(DiscBotCDReader *reader);

uint32_t discbot_cd_reader_track_count(const DiscBotCDReader *reader);
uint8_t discbot_cd_reader_track_number(const DiscBotCDReader *reader, uint32_t index);
uint8_t discbot_cd_reader_track_session(const DiscBotCDReader *reader, uint32_t index);
uint8_t discbot_cd_reader_track_control(const DiscBotCDReader *reader, uint32_t index);
uint32_t discbot_cd_reader_track_start_lba(const DiscBotCDReader *reader, uint32_t index);
uint32_t discbot_cd_reader_leadout_lba(const DiscBotCDReader *reader);

/*
 * Reads complete raw sectors (sync/header/user/auxiliary as applicable).
 * The destination must hold sector_count * DISCBOT_CD_SECTOR_SIZE bytes.
 */
int discbot_cd_reader_read(
    DiscBotCDReader *reader,
    uint32_t start_lba,
    uint32_t sector_count,
    void *destination,
    uint32_t *sectors_read,
    char *error_buffer,
    size_t error_buffer_length
);

#ifdef __cplusplus
}
#endif

#endif /* DISCBOT_CD_READER_H */
