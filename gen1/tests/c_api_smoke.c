#include "tbdf1.h"

#include <stdlib.h>
#include <string.h>

typedef struct test_disk {
    uint8_t bytes[16 * 64];
} test_disk;

static int read_block(void *context, uint32_t block, uint8_t *output,
                      size_t length) {
    test_disk *disk = (test_disk *)context;
    if (block >= 16 || length != 64) return -1;
    memcpy(output, &disk->bytes[block * 64], length);
    return 0;
}

static int write_block(void *context, uint32_t block, const uint8_t *input,
                       size_t length) {
    test_disk *disk = (test_disk *)context;
    if (block >= 16 || length != 64) return -1;
    memcpy(&disk->bytes[block * 64], input, length);
    return 0;
}

int main(void) {
    test_disk disk = {{0}};
    tbdf_device device = {
        .context = &disk,
        .block_size = 64,
        .block_count = 16,
        .read_block = read_block,
        .write_block = write_block,
    };
    uint8_t scratch[64 + 64];
    void *storage = malloc(tbdf_volume_storage_size());
    if (storage == NULL) return 1;

    if (tbdf_format(&device, scratch, sizeof scratch) != TBDF_OK) return 2;
    if (tbdf_volume_open(storage, tbdf_volume_storage_size(), &device,
                         scratch, sizeof scratch) != TBDF_OK)
        return 3;

    tbdf_file_info file;
    if (tbdf_create(storage, 0, (const uint8_t *)"c-smoke", 7,
                    TBDF_FILE_REGULAR, &file) != TBDF_OK)
        return 4;
    const uint8_t input[] = {1, 2, 3, 4};
    size_t written = 0;
    if (tbdf_write_at(storage, file.id, 0, input, sizeof input, &written) !=
            TBDF_OK ||
        written != sizeof input)
        return 5;

    uint8_t output[sizeof input] = {0};
    size_t read = 0;
    if (tbdf_read_at(storage, file.id, 0, output, sizeof output, &read) !=
            TBDF_OK ||
        read != sizeof input || memcmp(input, output, sizeof input) != 0)
        return 6;

    if (tbdf_volume_close(storage, tbdf_volume_storage_size()) != TBDF_OK)
        return 7;
    free(storage);
    return 0;
}
