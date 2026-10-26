# TBDF1 Zig library

This package reads, validates, formats, and updates TBDF1 disk images. The
format is specified in [docs/TBDF1.md](../docs/TBDF1.md).

The package also provides a C ABI. Include [`include/tbdf1.h`](include/tbdf1.h)
and link the static `tbdf1` library installed by `zig build install`.

The library uses no allocator and retains no disk-sized metadata. **The caller
provides a block device and a scratch slice of `block_size + 64` bytes.** The
first block-sized part is used for block I/O; the remaining 64 bytes stage a
single table record. Keep the device and scratch alive for the lifetime of a
mounted volume. A volume is not reentrant, and payload slices must not overlap
its scratch memory.

## Connect a block device

The callbacks adapt the library to a simulator, a disk image, or a physical
device. The library only asks for one block at a time.

```zig
const tbdf = @import("tbdf1");
const block_size = 1024;

fn readBlock(context: ?*anyopaque, block: u32, output: []u8) anyerror!void {
    const disk: *Disk = @ptrCast(@alignCast(context.?));
    try disk.read(block, output);
}

fn writeBlock(context: ?*anyopaque, block: u32, input: []const u8) anyerror!void {
    const disk: *Disk = @ptrCast(@alignCast(context.?));
    try disk.write(block, input);
}

var device = tbdf.BlockDevice{
    .context = @ptrCast(&disk),
    .block_size = block_size,
    .block_count = disk.block_count,
    .read_block = readBlock,
    .write_block = writeBlock,
};
var scratch: [block_size + 64]u8 = undefined;
var volume = try tbdf.Volume.open(device, &scratch);
```

For read-only access, omit `.write_block`. Opening still performs full
validation. Validation uses repeated scans to keep memory bounded, so a large
image can require many device reads.

## Format a new image

Formatting writes block 0 and the first index block. The other blocks remain
untouched and start free in the new bitmap.

```zig
try tbdf.format(device, &scratch);
var volume = try tbdf.Volume.open(device, &scratch);
```

Use the default geometry constraints from the format specification: at least
eight blocks, at least 64 bytes per block, and enough bitmap bits to represent
the whole device.

## Browse and stream a file

IDs and file kinds are typed. `lookup` uses exact, case-sensitive names.
Directory iteration copies each name into caller-provided memory.

```zig
const entry = (try volume.lookup(.root, "notes")) orelse return error.NotFound;
var name_buffer: [64]u8 = undefined;
var cursor: u32 = 0;
while (try volume.listNext(entry.id, &cursor, &name_buffer)) |child| {
    // Consume child.info and name_buffer[0..child.name_length].
}

const file = (try volume.lookup(entry.id, "readme.txt")) orelse return error.NotFound;
var buffer: [512]u8 = undefined;
var offset: u64 = 0;
while (true) {
    const count = try volume.readAt(file.id, offset, &buffer);
    if (count == 0) break;
    try consume(buffer[0..count]);
    offset += count;
}
```

`readAt` returns zero at EOF and streams across block and extent boundaries.
It does not allocate a whole-file buffer.

## Create and update a file

Writes can replace existing bytes or extend exactly at EOF. They reject gaps.
Use `resize` to grow with zero-filled bytes or shrink and release trailing
allocation.

```zig
const file = try volume.create(.root, "capture.bin", .regular);
_ = try volume.writeAt(file.id, 0, payload);
try volume.resize(file.id, 4096);
try volume.delete(file.id);
```

Each write and resize checks the complete requested change before its first
write. If the device reports a write failure after mutation begins, the volume
is invalidated because TBDF1 has no transaction or recovery mechanism. Open
and validate the image again before using it.

## Supported layouts

The library reads default images and valid layouts using feature bits 0, 1, 2,
3, or 5, including supported combinations. Non-default images are read-only.
Unknown bits, the undefined combination of bits 0 and 1, and bit 4 extended
names are rejected. Formatting and mutation use the default layout only.

Build the library with `zig build`; run its tests with `zig build test`. A
freestanding WebAssembly build can be selected with `-Dtarget=wasm32-freestanding`.

## C API

The C interface mirrors the streaming Zig API and uses explicit pointer lengths.
It does not allocate memory. The caller allocates the opaque volume storage
using `tbdf_volume_storage_size()` and keeps it, the `block_size + 64` scratch
buffer, and the block callback context alive until `tbdf_volume_close()`. Use
`malloc()` for storage on supported targets; the reported alignment is also
available through `tbdf_volume_storage_align()`.

Block callbacks return zero on success and any nonzero value on failure. A
callback failure is reported as `TBDF_IO_ERROR`; if it occurs after a mutation
starts, the volume reports `TBDF_VOLUME_INVALIDATED` on later operations. C
functions return a `tbdf_status`; streaming read and write calls also return a
byte count through an output parameter. `tbdf_list_next` returns `TBDF_END`
after the final entry.

```c
#include "tbdf1.h"
#include <stdlib.h>

void *volume_storage = malloc(tbdf_volume_storage_size());
if (volume_storage == NULL) return 1;
uint8_t scratch[1024 + 64];
tbdf_device device = {
    .context = disk_context, /* your block device context */
    .block_size = 1024,
    .block_count = disk_block_count,
    .read_block = disk_read_block, /* callbacks return zero on success */
    .write_block = disk_write_block,
};

if (tbdf_volume_open(volume_storage, tbdf_volume_storage_size(), &device,
                     scratch, sizeof scratch) != TBDF_OK) {
    free(volume_storage);
    return 1;
}

tbdf_file_info file;
if (tbdf_create(volume_storage, 0, (const uint8_t *)"capture.bin", 11,
                TBDF_FILE_REGULAR, &file) == TBDF_OK) {
    size_t written;
    (void)tbdf_write_at(volume_storage, file.id, 0, payload, payload_size,
                        &written);
}
tbdf_volume_close(volume_storage, tbdf_volume_storage_size());
free(volume_storage);
```
