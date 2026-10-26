#ifndef TBDFV1_H
#define TBDFV1_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum tbdf_status {
    TBDF_OK = 0,
    TBDF_END = 1,
    TBDF_INVALID_ARGUMENT = 2,
    TBDF_INVALID_IMAGE = 3,
    TBDF_UNSUPPORTED_FEATURE = 4,
    TBDF_NOT_FOUND = 5,
    TBDF_ALREADY_EXISTS = 6,
    TBDF_NOT_DIRECTORY = 7,
    TBDF_IS_DIRECTORY = 8,
    TBDF_READ_ONLY = 9,
    TBDF_NO_SPACE = 10,
    TBDF_ID_EXHAUSTED = 11,
    TBDF_BUFFER_TOO_SMALL = 12,
    TBDF_VOLUME_INVALIDATED = 13,
    TBDF_IO_ERROR = 14,
    TBDF_INTERNAL_ERROR = 15
} tbdf_status;

typedef enum tbdf_file_kind {
    TBDF_FILE_REGULAR = 1,
    TBDF_FILE_DIRECTORY = 2
} tbdf_file_kind;

typedef int (*tbdf_read_block_fn)(void *context, uint32_t block,
                                  uint8_t *output, size_t length);
typedef int (*tbdf_write_block_fn)(void *context, uint32_t block,
                                   const uint8_t *input, size_t length);

typedef struct tbdf_device {
    void *context;
    uint32_t block_size;
    uint32_t block_count;
    tbdf_read_block_fn read_block;
    tbdf_write_block_fn write_block; /* NULL makes the device read-only. */
} tbdf_device;

typedef struct tbdf_file_info {
    uint16_t id;
    uint16_t parent;
    uint8_t kind;        /* tbdf_file_kind */
    uint8_t read_only;   /* 0 or 1 */
    uint16_t reserved;
    uint32_t regular_size;   /* zero for directories */
    uint32_t direct_children; /* zero for regular files */
} tbdf_file_info;

/* Allocate this many bytes for the opaque volume handle. malloc() provides
 * sufficient alignment on supported targets. Storage and scratch must not
 * overlap, and both must remain valid until close. */
size_t tbdf_volume_storage_size(void);
size_t tbdf_volume_storage_align(void);

/* The scratch buffer must be at least block_size + 64 bytes. */
tbdf_status tbdf_format(const tbdf_device *device,
                        uint8_t *scratch, size_t scratch_length);
tbdf_status tbdf_volume_open(void *storage, size_t storage_length,
                             const tbdf_device *device,
                             uint8_t *scratch, size_t scratch_length);
tbdf_status tbdf_volume_close(void *storage, size_t storage_length);

tbdf_status tbdf_stat(void *volume, uint16_t id, tbdf_file_info *output);
tbdf_status tbdf_lookup(void *volume, uint16_t parent,
                        const uint8_t *name, size_t name_length,
                        tbdf_file_info *output);
/* Returns TBDF_END when exhausted. On TBDF_OK, name_length is set to the
 * copied name length; TBDF_BUFFER_TOO_SMALL leaves the cursor unchanged. */
tbdf_status tbdf_list_next(void *volume, uint16_t parent, uint32_t *cursor,
                           uint8_t *name_output, size_t name_capacity,
                           size_t *name_length, tbdf_file_info *output);
tbdf_status tbdf_read_at(void *volume, uint16_t file_id, uint64_t offset,
                         uint8_t *output, size_t output_length,
                         size_t *bytes_read);
tbdf_status tbdf_write_at(void *volume, uint16_t file_id, uint64_t offset,
                          const uint8_t *input, size_t input_length,
                          size_t *bytes_written);
tbdf_status tbdf_resize(void *volume, uint16_t file_id, uint64_t new_size);
tbdf_status tbdf_create(void *volume, uint16_t parent,
                        const uint8_t *name, size_t name_length,
                        uint8_t kind, tbdf_file_info *output);
tbdf_status tbdf_delete(void *volume, uint16_t file_id);

#ifdef __cplusplus
}
#endif

#endif /* TBDFV1_H */
