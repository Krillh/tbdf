//! TBDFv1 wire representations and checked little-endian codecs.
//!
//! These routines only decode/encode fields. They do not validate cross-record
//! invariants, table bounds, or whether a feature combination is supported.

pub const disk_magic: u32 = 0x2CB8858E;
pub const format_id: u32 = 0x0BDF0001;
pub const no_link: u16 = 0xFFFF;
pub const extent_page_bytes: usize = 64;
pub const extent_entries_per_page: usize = 7;
pub const file_entry_bytes: usize = 12;
pub const max_name_bytes: usize = 64;
pub const default_index_header_bytes: usize = 64;
pub const fixed_index_header_bytes: usize = 32;

pub const WireError = error{InvalidLength};

pub const DiskHeader = struct {
    magic: u32,
    format: u32,
    block_size: u32,
    disk_blocks: u32,
    index_blocks: u16,
    feature_flags: u32,
};

/// Offsets are relative to the index header. In the fixed layout file_offset
/// is implicit (32); first_available fields stay wide in memory.
pub const IndexHeader = struct {
    file_offset: u32,
    file_first_available: u32,
    file_capacity: u32,
    name_offset: u32,
    name_first_available: u32,
    name_capacity: u32,
    extent_offset: u32,
    extent_first_available: u32,
    extent_capacity: u32,
};

pub const FileEntry = struct {
    id: u16,
    parent_or_flags: u16,
    name_index: u16,
    first_extent: u16,
    size_or_children: u32,
};

/// A fixed-size name slot. Only the first `size` bytes are part of the wire
/// entry; unused tail bytes are not interpreted by this codec.
pub const NameEntry = struct {
    bytes: [64]u8 = @splat(0),
    size: u8,
};

pub const Extent = struct {
    start_block: u32,
    block_count: u32,
};

pub const ExtentPage = struct {
    ordinal: u16,
    next: u16,
    previous: u16,
    entries: [extent_entries_per_page]Extent,
};

fn get(comptime T: type, bytes: []const u8, at: usize) T {
    var value: T = 0;
    inline for (0..@sizeOf(T)) |i| value |= @as(T, bytes[at + i]) << @intCast(i * 8);
    return value;
}

fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    inline for (0..@sizeOf(T)) |i| bytes[at + i] = @truncate(value >> @intCast(i * 8));
}

fn need(bytes_len: usize, size: usize) WireError!void {
    if (bytes_len < size) return error.InvalidLength;
}

/// Header size includes the reserved padding before the bitmap: 32 normally,
/// 24 when reduced-padding (bit 5) is enabled.
pub fn decodeDiskHeader(bytes: []const u8, reduced_padding: bool) WireError!DiskHeader {
    const size: usize = if (reduced_padding) 24 else 32;
    try need(bytes.len, size);
    return .{
        .magic = get(u32, bytes, 0),
        .format = get(u32, bytes, 4),
        .block_size = get(u32, bytes, 8),
        .disk_blocks = get(u32, bytes, 12),
        .index_blocks = get(u16, bytes, 16),
        .feature_flags = get(u32, bytes, 18),
    };
}

pub fn encodeDiskHeader(bytes: []u8, header: DiskHeader, reduced_padding: bool) WireError!void {
    const size: usize = if (reduced_padding) 24 else 32;
    try need(bytes.len, size);
    put(u32, bytes, 0, header.magic);
    put(u32, bytes, 4, header.format);
    put(u32, bytes, 8, header.block_size);
    put(u32, bytes, 12, header.disk_blocks);
    put(u16, bytes, 16, header.index_blocks);
    put(u32, bytes, 18, header.feature_flags);
}

pub fn decodeIndexHeader(bytes: []const u8, fixed_location: bool) WireError!IndexHeader {
    if (fixed_location) {
        try need(bytes.len, fixed_index_header_bytes);
        return .{
            .file_offset = 32,
            .file_first_available = get(u16, bytes, 20),
            .file_capacity = get(u32, bytes, 8),
            .name_offset = get(u32, bytes, 0),
            .name_first_available = get(u16, bytes, 22),
            .name_capacity = get(u32, bytes, 12),
            .extent_offset = get(u32, bytes, 4),
            .extent_first_available = get(u16, bytes, 24),
            .extent_capacity = get(u32, bytes, 16),
        };
    }
    try need(bytes.len, default_index_header_bytes);
    return .{
        .file_offset = get(u32, bytes, 0),
        .file_first_available = get(u32, bytes, 4),
        .file_capacity = get(u32, bytes, 8),
        .name_offset = get(u32, bytes, 12),
        .name_first_available = get(u32, bytes, 16),
        .name_capacity = get(u32, bytes, 20),
        .extent_offset = get(u32, bytes, 24),
        .extent_first_available = get(u32, bytes, 28),
        .extent_capacity = get(u32, bytes, 32),
    };
}

pub fn encodeIndexHeader(bytes: []u8, header: IndexHeader, fixed_location: bool) WireError!void {
    if (fixed_location) {
        try need(bytes.len, fixed_index_header_bytes);
        if (header.file_offset != 32 or header.file_first_available > 0xFFFF or
            header.name_first_available > 0xFFFF or header.extent_first_available > 0xFFFF)
            return error.InvalidLength;
        put(u32, bytes, 0, header.name_offset);
        put(u32, bytes, 4, header.extent_offset);
        put(u32, bytes, 8, header.file_capacity);
        put(u32, bytes, 12, header.name_capacity);
        put(u32, bytes, 16, header.extent_capacity);
        put(u16, bytes, 20, @intCast(header.file_first_available));
        put(u16, bytes, 22, @intCast(header.name_first_available));
        put(u16, bytes, 24, @intCast(header.extent_first_available));
        return;
    }
    try need(bytes.len, default_index_header_bytes);
    put(u32, bytes, 0, header.file_offset);
    put(u32, bytes, 4, header.file_first_available);
    put(u32, bytes, 8, header.file_capacity);
    put(u32, bytes, 12, header.name_offset);
    put(u32, bytes, 16, header.name_first_available);
    put(u32, bytes, 20, header.name_capacity);
    put(u32, bytes, 24, header.extent_offset);
    put(u32, bytes, 28, header.extent_first_available);
    put(u32, bytes, 32, header.extent_capacity);
}

pub fn decodeFileEntry(bytes: []const u8) WireError!FileEntry {
    try need(bytes.len, file_entry_bytes);
    return .{
        .id = get(u16, bytes, 0),
        .parent_or_flags = get(u16, bytes, 2),
        .name_index = get(u16, bytes, 4),
        .first_extent = get(u16, bytes, 6),
        .size_or_children = get(u32, bytes, 8),
    };
}

pub fn encodeFileEntry(bytes: []u8, entry: FileEntry) WireError!void {
    try need(bytes.len, file_entry_bytes);
    put(u16, bytes, 0, entry.id);
    put(u16, bytes, 2, entry.parent_or_flags);
    put(u16, bytes, 4, entry.name_index);
    put(u16, bytes, 6, entry.first_extent);
    put(u32, bytes, 8, entry.size_or_children);
}

pub fn decodeNameEntry(bytes: []const u8, size: u8) WireError!NameEntry {
    if (size != 16 and size != 32 and size != 64) return error.InvalidLength;
    const n: usize = size;
    try need(bytes.len, n);
    var entry = NameEntry{ .size = size };
    @memcpy(entry.bytes[0..n], bytes[0..n]);
    return entry;
}

pub fn encodeNameEntry(bytes: []u8, entry: NameEntry) WireError!void {
    if (entry.size != 16 and entry.size != 32 and entry.size != 64) return error.InvalidLength;
    const n: usize = entry.size;
    try need(bytes.len, n);
    @memcpy(bytes[0..n], entry.bytes[0..n]);
}

pub fn decodeExtentPage(bytes: []const u8) WireError!ExtentPage {
    try need(bytes.len, extent_page_bytes);
    var page: ExtentPage = .{
        .ordinal = get(u16, bytes, 0),
        .next = get(u16, bytes, 2),
        .previous = get(u16, bytes, 4),
        .entries = undefined,
    };
    for (&page.entries, 0..) |*entry, i| {
        const at = 8 + i * 8;
        entry.* = .{ .start_block = get(u32, bytes, at), .block_count = get(u32, bytes, at + 4) };
    }
    return page;
}

pub fn encodeExtentPage(bytes: []u8, page: ExtentPage) WireError!void {
    try need(bytes.len, extent_page_bytes);
    put(u16, bytes, 0, page.ordinal);
    put(u16, bytes, 2, page.next);
    put(u16, bytes, 4, page.previous);
    // Bytes 6..8 are reserved and intentionally left untouched.
    for (page.entries, 0..) |entry, i| {
        const at = 8 + i * 8;
        put(u32, bytes, at, entry.start_block);
        put(u32, bytes, at + 4, entry.block_count);
    }
}
