# Tiny Basic Disk Format version 1

TBDFv1, OpenWAC's official and only supported disk format, provides minimal
fixed-geometry block storage down to 256 bytes (eight 32-byte blocks with
the required features).

## Conventions and validity

- Integers are unsigned, little-endian (least significant byte at lowest
  offset); sizes/offsets are bytes unless stated otherwise; indexes are
  zero-based; `[x, y)` excludes `y`.
- Notation: `B` = block size, `D` = disk block count, `I` = index block count,
  `H` = index header size, `N` = name-entry size. For each table, `a` denotes
  `first_available` and `c` denotes capacity.
- This specification defines the disk format, independently of simulator
  limits or a driver API. Any whole-byte block size satisfying its field,
  bitmap, minimum-size, and layout constraints is permitted; no power-of-two
  or additional block-size alignment requirement applies. Devices and
  implementations may impose their own limits outside the format.
- Ignore all reserved bytes/padding regardless of value; zero is not required.
  Reserved IDs and sentinels retain their specified meanings.
- Reject completed images violating the required invariants below.
  Recommendations and explicitly optional behavior are not requirements.
  In-progress writes need not form a valid image; see [Safety](#safety).
- Use sufficiently wide unsigned integers or checked arithmetic for all
  disk/index/table/extent bounds, ordinals, allocation totals, required
  sizes, and child-count updates. Overflow, underflow, wrapping, or
  truncation must not turn an invalid value or range into a valid one.

## Disk header and bitmap

Block 0 contains the header followed by the occupancy bitmap. In the table,
`default / reduced` selects the layout without / with feature bit 5
(`disk-header-reduced-padding`); the first 22 bytes are common.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic: `0x2CB8858E` |
| 4 | 4 | Format identifier: `0x0BDF0001` |
| 8 | 4 | Block size, `B` |
| 12 | 4 | Disk block count, `D` |
| 16 | 2 | Index block count, `I` |
| 18 | 4 | Feature flags |
| 22 | 10 / 2 | Reserved |
| 32 / 24 | `B - 32` / `B - 24` | Occupancy bitmap; remainder of block 0 |

OpenWAC-standard persistent storage uses these first eight bytes for magic
and format identifiers. Read block 0 using reported device geometry;
recorded `B` and `D` must match it exactly.

Required geometry:

```text
D >= 8
1 <= I < D
B >= 32, if both bits 2 and 5 are enabled; otherwise B >= 64
bitmap_offset = 24 if bit 5 is enabled, otherwise 32
bitmap_bits = (B - bitmap_offset) * 8
D <= bitmap_bits
```

Bitmap byte `i / 8`, bit `i % 8` (bit 0 = least significant bit), describes
block `i`. For real blocks, `1` means occupied and `0` means free. Its exact
required contents are:

- Set bits for block 0, index blocks `1..I` inclusive, and every block in
  every file extent, including preallocation beyond EOF and hidden name
  metadata.
- Clear every other real-block bit: allocated but unreferenced real blocks
  are forbidden.
- Set all bits for indexes `D..bitmap_bits-1`, reserving nonexistent blocks;
  these bits are not real allocations.

Reject any mismatch as corruption; do not silently repair or allocate from
an inconsistent bitmap. Validation supplies no crash recovery.

Default minimum: eight 64-byte blocks = 512 bytes. At `B = 64` with the
32-byte bitmap offset, 256 blocks are representable, totaling 16,384 bytes.
Bits 2+5 permit the absolute minimum of eight 32-byte blocks = 256 bytes;
at `B = 32`, the reduced bitmap represents at most 64 blocks = 2,048 bytes.
Larger blocks increase bitmap capacity according to the formula above.

## Index file

The index is metadata, not a file-table entry. It occupies contiguous blocks
`1..I`, starting with an index header and containing file, name, and extent
tables. `H` is 64 by default or 32 with bit 2 enabled. The entire header must
fit in block 1. Tables, entries, extent pages, and individual fields may
cross block boundaries without inserted padding; alignment constrains table
starts, not each entry or block.

### Default index header

36 field bytes + 28 reserved bytes = 64 bytes. All defined fields are four-byte
unsigned integers; `first_available` retains this width for forward
compatibility.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | File table offset |
| 4 | 4 | File table first available index |
| 8 | 4 | File table capacity |
| 12 | 4 | Name table offset |
| 16 | 4 | Name table first available index |
| 20 | 4 | Name table capacity |
| 24 | 4 | Extent table offset |
| 28 | 4 | Extent table first available index |
| 32 | 4 | Extent table capacity |
| 36 | 28 | Reserved |

### Fixed-location index header (bit 2)

26 field bytes + 6 reserved bytes = 32 bytes. The file table immediately
follows at implicit offset 32, preserving its 32-byte alignment. Remaining
offsets precede capacities, then two-byte first-available fields; four-byte
fields are four-byte aligned and two-byte fields two-byte aligned.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | Name table offset |
| 4 | 4 | Extent table offset |
| 8 | 4 | File table capacity |
| 12 | 4 | Name table capacity |
| 16 | 4 | Extent table capacity |
| 20 | 2 | File table first available index |
| 22 | 2 | Name table first available index |
| 24 | 2 | Extent table first available index |
| 26 | 6 | Reserved |

Offsets/capacities remain four bytes; bit 2 changes layout and widths and
cannot be ignored.

### Table bounds and limits

Offsets are relative to the start of the index header. Capacity and indexes
use these slot units; extent slots are pages, not eight-byte extent records.

| Table | Slot bytes | Default table alignment | Maximum capacity: default / bit 2 |
| --- | ---: | ---: | ---: |
| File | 12 | 32 | 65,534 / 65,534 |
| Name | `N` = 16, 32, or 64 | 64 | 65,536 / 65,535 |
| Extent | 64 | 64 | 65,535 / 65,535 |

For each table, including the implicit fixed file table:

```text
index_bytes = I * B
alignment = max(H, default_table_alignment)
H <= offset <= index_bytes
offset % alignment == 0
table_end = offset + c * slot_bytes
table_end <= index_bytes
```

Capacity regions `[offset, table_end)` include unused slots; nonempty regions
must not overlap each other or the header. Adjacency/gaps are allowed.
Zero-capacity tables have `a = 0` and reserve no bytes; their aligned,
in-bounds offsets may coincide with another table's or equal `index_bytes`.

IDs 0 and 1 are reserved, leaving 65,534 live file IDs (`2..65535`): 32,767
even directory IDs and 32,767 odd regular-file IDs. Creation must respect
both the total and per-type limits even when table space remains.

Name indexes have no sentinel: the default layout permits `0..65535`.
Extent indexes permit only `0..65534`; `0xFFFF` means no link. Capacity,
including unused slots, must respect the table limits. Reject over-limit
growth even when disk space remains. Wider default fields reserve room for
future extensions without relaxing current limits.

Full-table `a = c` must fit its field: default fields must retain 65,536
without narrowing to 16 bits. Bit 2 limits name capacity to 65,535, fitting
two-byte `a` and leaving name indexes `0..65534`. Here `a = 0xFFFF` can mean
full; it is not a link sentinel.

### First available slot and reuse

`a` is the lowest unused slot index, or `c` when every slot is used:
`0 <= a <= c`; the table is full iff `a == c`. Empty tables have `a = 0`;
a zero-capacity table is also full. A value below capacity must identify an
unused slot, with no unused slot before it.

For name and extent tables, `a` is neither a live count nor a reference
bound: later slots may be occupied. Enumerate/validate the whole capacity;
references must be below capacity and identify in-use slots, except defined
no-link sentinels. In-use name slots have a nonzero first byte; in-use
extent pages have a nonzero ordinal.

After removing references to a deleted slot `i`, set its unused marker
(name first byte or page ordinal) to zero and set `a = min(a, i)`. Other
slots do not move. Allocate at `a`, then scan forward for the next unused
slot or set `a = c` if none remains. Initialize unused markers throughout
new tables and newly added capacity; preserve existing markers when
relocating. Growing a full table sets `a` to its old capacity; growing a
nonfull table leaves `a` unchanged. File entries instead remain packed as
specified below.

### Growth and relocation

Index growth must remain contiguous, moving any displaced occupied blocks.
Before writing, plan a feasible layout including table expansion/relocation,
displaced data, and temporary disk space required by the chosen strategy.
Insufficient space must prevent modifications from beginning; no relocation
algorithm is prescribed.

Completed growth must preserve file IDs, parents, direct-child counts,
names, hidden name metadata, and logical contents. Update affected table
offsets, references, extent links and data extents; resulting index size,
capacities, first-available indexes, and bitmap must satisfy all invariants.
These requirements concern planning and completed images, not transactions
or a driver API. Intermediate images may be invalid, and failed writes may
leave incomplete updates; optional retries may allow completion.

## File table

Entries are 12 bytes; table alignment is `max(H, 32)`:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 2 | File ID |
| 2 | 2 | Parent ID / readonly flag |
| 4 | 2 | Name entry index |
| 6 | 2 | First extent page index |
| 8 | 4 | Logical byte size (regular file) / direct-child count (directory) |

### Packing and identity

Slots `[0, a)` are live and packed; `a` is also the live-entry count. Slots
`[a, c)` are unused capacity with ignored contents; there is no unused-file
marker. Table order has no significance.

Create by appending at `a` (grow capacity first if needed), then increment
`a`. Delete by moving the last live entry into the removed slot unless it
was already last, then decrement `a`; do not set `a` to the deleted slot's
index. Preserve every moved field, including IDs and name/extent references;
clearing the vacated slot is recommended, not required. IDs identify files,
not file-table positions.

File IDs are unique: even IDs identify directories, odd IDs regular files.
ID 0 is the implicit root, with no entry; ID 1 also cannot identify an entry.
When feature bit 3 is enabled, clear stored-parent bit 0 before parent
lookup, comparison, hierarchy validation, or child checks. Without bit 3,
an odd parent field is invalid. Changing readonly status does not reparent.

Creation requires a directory parent that already exists, or root. File ID
and resolved parent ID remain fixed for the entry's lifetime, including
packed-table moves. In-place reparenting is forbidden; changing parents
requires deletion and creation under these rules. Only leaves may be
deleted: regular files have no children, directories require child count
zero, and root cannot be deleted. Completed deletion releases the owned
name slot, extent pages and data blocks, updates first-available indexes
and bitmap, and preserves file-table packing.

From a valid image these mutations preserve an acyclic rooted hierarchy;
existing images must still be validated. Every resolved parent must be root
or an existing directory, and every parent chain must reach root. Missing
parents, self-parenting and cycles are corruption.

### Size, children and ownership

For regular files, offset 8 stores logical bytes; for directories it stores
the exact count of live entries whose resolved parent equals the directory
ID. Count direct files and subdirectories only, excluding deeper descendants.
New directories start at zero. Completed creation/deletion increments/
decrements only the direct parent's stored count (unless parent is root);
ancestor counts do not change. Reject mismatches against actual children.
Once validated and maintained, zero suffices for a fast emptiness check.
Root has no stored count; its direct children have resolved parent ID 0.

Directories always have first extent index `0xFFFF`, regardless of count;
children are represented by parent IDs, not allocated directory data.
Every live entry, including directories, owns exactly one in-use name slot.
Every in-use name slot must have exactly one owner; sharing is forbidden
even across parents. Every in-use extent page must belong to exactly one
regular file's chain; directories cannot own pages. Unreferenced in-use
name slots or pages are errors.

Name/extent references are slot indexes, not byte offsets; first extent
`0xFFFF` means no pages. Regular files without extents have size zero;
zero-size files may own extents. Directory child counts require no data
allocation. Marked files exclude the 256-byte name prefix from logical size
but allocate it even at size zero; see [Extended names](#extended-names-bit-4).

## Name table

Default table alignment is 64 bytes; `N` is 32 by default, 16 with bit 0,
or 64 with bit 1. Each fixed-size entry holds a nonempty, case-sensitive
name. Terminate with NUL unless all `N` bytes are name bytes, in which case
length is `N`. First byte zero marks an unused entry. Validation/comparison
stop at the terminator; trailing bytes are ignored. Zeroing all trailing
bytes and unused entries is recommended, not required.

Decoded name bytes must be printable ASCII `0x20..0x7E`, including spaces
and all punctuation. Controls `0x00..0x1F` and DEL `0x7F` are forbidden as
name bytes; NUL remains the terminator/unused marker. Clear an enabled
extended-name marker before validation/comparison. TBDF reserves no printable
names or characters: `.`, `..`, a single space, `/`, and backslash are valid;
higher-level filesystems may impose their own restrictions/interpretations.

Each file's name index must be below name capacity and reference an in-use
entry. Every in-use entry has exactly one live owner; unused entries cannot
be referenced. Different parents may use identical name bytes, but require
separate slots. Within one resolved parent, decoded table names must be
unique, including extended-name prefixes: two full names cannot share a
prefix, and a marked prefix cannot equal an unmarked name. Higher-layer
naming or aliases must preserve this invariant.

## Extent table

Table alignment is `max(H, 64)`; each 64-byte page contains:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 2 | Page ordinal |
| 2 | 2 | Forward page index (`next`) |
| 4 | 2 | Backward page index (`previous`) |
| 6 | 2 | Reserved |
| 8 | 56 | Seven eight-byte extent entries |

### Pages and links

Links are page indexes, not ordinals. `0xFFFF` explicitly means no link;
all other links and file-head indexes must be below extent capacity and
reference in-use pages. A file-head value `0xFFFF` means no pages. Each
in-use page must be reachable from exactly one regular file's head; shared,
unreferenced, repeated or cyclic pages are errors.

A chain's first page has ordinal 1 and `previous = 0xFFFF`; every next page
has ordinal exactly predecessor + 1, with reciprocal forward/backward links.
The last page has `next = 0xFFFF`. Skips, equal/decreasing ordinals, wrapping,
or incorrect endpoint/reciprocal links are errors. Ordinal `0xFFFF` is a
valid final ordinal, distinct from a no-link index; a chain has at most
65,535 pages.

Ordinal zero marks an unused page, which no live entry or in-use page may reference.
Its other fields are ignored; setting both links to `0xFFFF` is recommended.
Chain/entry rules apply only to in-use pages; reserved bytes are ignored.

### Entries, order and allocation

Each entry is `start_block:u32, block_count:u32`. A zero count marks unused;
ignore its start and preferably zero both fields. For each used extent:

```text
start_block > I
end_block = start_block + block_count
end_block <= D
```

It owns `[start_block, end_block)`. Extents cannot overlap block 0, the index,
or any other used extent within or across files. Adjacent extents are valid;
shared blocks are not.

Nonfinal pages require seven used entries. A final page requires
`next = 0xFFFF` and 0-7 used entries followed only by unused entries; seven
used entries with no unused tail is valid. An unused entry before a used
entry, or any unused entry in a page with a next link, is an error. Empty
entries must not be skipped.

Concatenate extents in slot order, then forward-linked page/ordinal order;
inside an extent, bytes follow increasing block index then byte offset.
Table/page metadata and unused slots contribute no file bytes. Physical
gaps between extents are allowed but create no logical gaps: sparse files
and implicit content gaps are unsupported.

For each regular file:

```text
allocated_bytes = sum(block_count across its used extents) * B
required_bytes = logical_size + (256 if extended-name marked, otherwise 0)
allocated_bytes >= required_bytes
```

Extra allocation is permitted, even with logical size zero. Ordinary reads
expose only logical contents, excluding hidden name metadata. Directory
child counts do not participate in this allocation calculation.

## Optional features

Flag bits are numbered from least significant bit 0. Unknown/undefined bits
or combinations require rejection; bits 0+1 select an undefined feature,
not either name size or a combination of sizes. With no flags, default
layouts/name rules apply and no extended-name prefix handling is needed.

`Safe to ignore` permits omitting optional behavior while honoring all
storage/decoding rules. For example, readonly enforcement may be omitted,
but parent-bit masking remains mandatory. Other features require storage
support even if higher-layer functionality is omitted. Reject a disk when
its enabled storage rules cannot be interpreted.

| Bit | Safe to ignore? | Feature |
| --- | --- | --- |
| 0 | No | 16-byte name entries |
| 1 | No | 64-byte name entries |
| 0+1 | No | Undefined feature |
| 2 | No | fixed-file-table-location |
| 3 | Yes, enforcement only | file-readonly-bit |
| 4 | No | extended-file-names |
| 5 | No | disk-header-reduced-padding |

Bits 0/1 change `N` and therefore name-slot index interpretation; unsupported
name sizes cannot be ignored.

### Fixed file table (bit 2)

Use the reordered [32-byte header](#fixed-location-index-header-bit-2),
implicit file offset 32, two-byte first-available fields, and compact name
capacity limit 65,535. Intended for truly small disks; less reserved space
and narrower fields limit forward compatibility.

### Readonly (bit 3)

Stored-parent bit 0 signals readonly for non-privileged processes. Directory
IDs are even, leaving this bit available. Clear it for parent lookup,
comparison, hierarchy validation and child checks even when enforcement is
omitted. Toggling it does not change the parent. Ignoring enforcement does
not corrupt storage; mandatory parent decoding still applies.

### Extended names (bit 4)

Regular file names may reach 256 bytes without changing `N`; this is distinct
from 64-byte name entries. A table entry is marked iff it has no terminator
and its last byte's high bit is set. Directories cannot be marked. Unmarked
files retain ordinary layout even when bit 4 is enabled.

A marked file's first 256 extent-backed bytes form a fixed hidden name
buffer. Its first `N` raw bytes must exactly equal the table entry, including
the marker at byte `N - 1`. Clear that bit when validating, comparing, or
returning either full name or table prefix; it is the sole exception to
printable ASCII storage, and decoded bytes must remain `0x20..0x7E`. No
marker exception applies with the feature disabled.

Full name length is `N..256`: NUL-terminate unless exactly 256 bytes, when
length is implied. Ignore trailing bytes after the terminator, preferably
zeroing them. Decoded table prefixes must remain unique among all names of
the same parent even when full names differ.

The full 256-byte buffer is metadata, excluded from logical size and ordinary
reads/writes. Logical offset `x` maps to extent-backed byte `256 + x`.
Allocation must cover `256 + logical_size`, including all 256 bytes when
logical size is zero. Ordinary writes cannot overwrite the buffer;
truncation to zero preserves it and its allocation. Rename must maintain
full-name/table-prefix consistency and adjust storage layout when adding
or removing the marker.

A driver may operate solely through unique decoded table names without
full-name lookup, marked-name creation, or marked-file renaming. It must
still recognize markers, obey offset/size/allocation rules, and preserve
hidden metadata on writes/truncation. Unsupported individual operations may
be rejected; inability to interpret storage requires rejecting the disk.
Invalid markers on directories, missing allocation, prefix mismatch,
invalid decoded names or duplicate decoded table names are format errors.

### Reduced disk-header padding (bit 5)

Move the bitmap start from byte 32 to 24, reducing reserved header padding
from ten to two bytes. With bit 2, this permits 32-byte blocks. Such blocks
have a 64-bit bitmap and a 64-block/2,048-byte disk limit. Intended only when
needed: consuming reserved header space may limit forward compatibility.

### Possible future features

Ideas only; implementation is not necessarily planned or expected:

- `extended-directory-names`: extend the regular-file naming approach to directories.
- `variable-length-file-names`: variable-sized names; no implementation design yet.
- `32-byte-extent-pages` / `16-byte-extent-pages`: three / one extent entries per page instead of seven.
- `no-file-size-field`: remove the file-entry size field; store size at the start of the file.
- `looping-extent-pages`: circular extent-page chains.
- `skippable-empty-extent-entries`: unused slots before used slots or in nonfinal pages; skipped slots contribute no file bytes and are not sparse contents. No bit is assigned; such layouts remain invalid.
- `implicit-table-offsets`: each table immediately follows its predecessor.
- `extended-disk-header`: a two-block header providing a larger bitmap.

## Safety

TBDFv1 has few corruption, crash-safety or recovery measures. Writes are
non-atomic; a crash during writing is very likely to corrupt data. Future
versions may add protections. No rollback or recovery is guaranteed.

A failed block write may have modified part of the block. A host/driver may
retain the intended full-block bytes and retry those same bytes at the same
block. Retries are optional implementation behavior without a feature flag.
A successful retry completes that block write; a multi-block update completes
only after remaining writes finish and the resulting image is valid.

Incomplete updates may leave inconsistent disks. TBDF specifies no driver
interface, error codes, retry count/timing, mandatory shutdown policy, or
flush operation; implementations choose failure reporting/handling. Successful
device writes add no durability guarantee against later host crashes or
power loss beyond the storage device's own guarantees.
