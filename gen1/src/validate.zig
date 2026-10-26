//! Allocation-free, repeated-scan TBDF1 validator.
const std = @import("std");
const wire = @import("wire.zig");
const io = @import("block_io.zig");
const VError = error{Corrupt};

pub const Result = struct {
    disk: wire.DiskHeader,
    index: wire.IndexHeader,
    header_size: u8,
    bitmap_offset: u8,
    name_size: u8,
    read_only: bool,
};

const Context = struct {
    device: io.BlockDevice,
    scratch: *io.Scratch,
    disk: wire.DiskHeader,
    index: wire.IndexHeader,
    h: u32,
    bitmap: u32,
    namesz: u32,
    index_bytes: u64,
};

fn rd(c: *Context, block: u32) anyerror![]u8 {
    if (block >= c.device.block_count) return error.Corrupt;
    return io.readBlock(c.device, c.scratch, block);
}

// Reads a byte range without retaining a block-buffer slice across callbacks.
// The destination is small fixed-size stack storage for one wire record/name.
fn readAt(c: *Context, offset: u64, out: []u8) anyerror!void {
    const end = std.math.add(u64, offset, @as(u64, @intCast(out.len))) catch return error.Corrupt;
    if (end > c.index_bytes) return error.Corrupt;
    var done: usize = 0;
    while (done < out.len) {
        const pos = offset + @as(u64, @intCast(done));
        const block: u32 = @intCast(1 + pos / c.disk.block_size);
        const in_block: usize = @intCast(pos % c.disk.block_size);
        const data = try rd(c, block);
        const take = @min(out.len - done, data.len - in_block);
        @memcpy(out[done .. done + take], data[in_block .. in_block + take]);
        done += take;
    }
}

fn fileAt(c: *Context, slot: u32) anyerror!wire.FileEntry {
    if (slot >= c.index.file_capacity) return error.Corrupt;
    var b: [12]u8 = undefined;
    try readAt(c, @as(u64, c.index.file_offset) + @as(u64, slot) * 12, &b);
    return wire.decodeFileEntry(&b);
}
fn nameAt(c: *Context, slot: u32) anyerror![64]u8 {
    if (slot >= c.index.name_capacity) return error.Corrupt;
    var b: [64]u8 = @splat(0);
    try readAt(c, @as(u64, c.index.name_offset) + @as(u64, slot) * c.namesz, b[0..@intCast(c.namesz)]);
    return b;
}
fn pageAt(c: *Context, slot: u32) anyerror!wire.ExtentPage {
    if (slot >= c.index.extent_capacity) return error.Corrupt;
    var b: [64]u8 = undefined;
    try readAt(c, @as(u64, c.index.extent_offset) + @as(u64, slot) * 64, &b);
    return wire.decodeExtentPage(&b);
}
fn parentOf(c: *Context, f: wire.FileEntry) VError!u16 {
    if ((c.disk.feature_flags & 8) != 0) return f.parent_or_flags & 0xFFFE;
    if ((f.parent_or_flags & 1) != 0) return error.Corrupt;
    return f.parent_or_flags;
}
fn findFile(c: *Context, id: u16) anyerror!?wire.FileEntry {
    var n: u32 = 0;
    while (n < c.index.file_first_available) : (n += 1) {
        const f = try fileAt(c, n);
        if (f.id == id) return f;
    }
    return null;
}
fn nameLen(b: []const u8, n: u32) u32 {
    for (0..@as(usize, @intCast(n))) |i| if (b[i] == 0) return @intCast(i);
    return n;
}
fn isDirectory(f: wire.FileEntry) bool {
    return (f.id & 1) == 0;
}

fn chainContains(c: *Context, f: wire.FileEntry, target: u16) anyerror!bool {
    var p = f.first_extent;
    var seen: u32 = 0;
    while (p != wire.no_link) : (seen += 1) {
        if (seen >= c.index.extent_capacity or p >= c.index.extent_capacity) return error.Corrupt;
        if (p == target) return true;
        const page = try pageAt(c, p);
        if (page.ordinal == 0) return error.Corrupt;
        p = page.next;
    }
    return false;
}

fn blockReferenced(c: *Context, target: u32) anyerror!bool {
    var fi: u32 = 0;
    while (fi < c.index.file_first_available) : (fi += 1) {
        const f = try fileAt(c, fi);
        if (isDirectory(f)) continue;
        var p = f.first_extent;
        var guard: u32 = 0;
        while (p != wire.no_link) : (guard += 1) {
            if (guard >= c.index.extent_capacity) return error.Corrupt;
            const pg = try pageAt(c, p);
            for (pg.entries) |e| if (e.block_count != 0 and target >= e.start_block and @as(u64, target) < @as(u64, e.start_block) + e.block_count) return true;
            p = pg.next;
        }
    }
    return false;
}

// Compare all used extents in locator order. Re-scanning avoids an allocation
// map; the lexicographic locator excludes a record from comparison with itself.
fn extentsDoNotOverlap(c: *Context) anyerror!void {
    var fa: u32 = 0;
    while (fa < c.index.file_first_available) : (fa += 1) {
        const f = try fileAt(c, fa);
        if (isDirectory(f)) continue;
        var pa = f.first_extent;
        var ga: u32 = 0;
        while (pa != wire.no_link) : (ga += 1) {
            if (ga >= c.index.extent_capacity) return error.Corrupt;
            const pga = try pageAt(c, pa);
            for (pga.entries, 0..) |ea, ia| {
                if (ea.block_count == 0) continue;
                var fb: u32 = fa;
                while (fb < c.index.file_first_available) : (fb += 1) {
                    const g = try fileAt(c, fb);
                    if (isDirectory(g)) continue;
                    var pb = if (fb == fa) pa else g.first_extent;
                    var gb: u32 = if (fb == fa) ga else 0;
                    while (pb != wire.no_link) : (gb += 1) {
                        if (gb >= c.index.extent_capacity) return error.Corrupt;
                        const pgb = try pageAt(c, pb);
                        for (pgb.entries, 0..) |eb, ib| {
                            if (eb.block_count == 0) continue;
                            if (fb == fa and (gb < ga or (gb == ga and ib <= ia))) continue;
                            const a0 = @as(u64, ea.start_block);
                            const a1 = a0 + ea.block_count;
                            const b0 = @as(u64, eb.start_block);
                            const b1 = b0 + eb.block_count;
                            if (a0 < b1 and b0 < a1) return error.Corrupt;
                        }
                        pb = pgb.next;
                    }
                }
            }
            pa = pga.next;
        }
    }
}

pub fn validate(device: io.BlockDevice, scratch: *io.Scratch) anyerror!Result {
    if (device.block_size < 32 or scratch.bytes.len < device.block_size) return error.Corrupt;
    const b0 = try io.readBlock(device, scratch, 0);
    if (b0.len != device.block_size) return error.Corrupt;
    const flags = @as(u32, b0[18]) | (@as(u32, b0[19]) << 8) | (@as(u32, b0[20]) << 16) | (@as(u32, b0[21]) << 24);
    const known: u32 = 0x3F;
    if ((flags & ~known) != 0 or (flags & 0x10) != 0 or (flags & 3) == 3) return error.UnsupportedFeature;
    const reduced = (flags & 0x20) != 0;
    const fixed = (flags & 4) != 0;
    const h: u32 = if (fixed) 32 else 64;
    const bitmap: u32 = if (reduced) 24 else 32;
    const minimum_block_size: u32 = if (fixed and reduced) 32 else 64;
    if (device.block_size < minimum_block_size) return error.Corrupt;
    const disk = try wire.decodeDiskHeader(b0, reduced);
    if (disk.magic != wire.disk_magic or disk.format != wire.format_id or disk.block_size != device.block_size or disk.disk_blocks != device.block_count) return error.Corrupt;
    const d = @as(u64, disk.disk_blocks);
    const ib = @as(u64, disk.index_blocks);
    const bm_bits = (@as(u64, device.block_size) - bitmap) * 8;
    if (d < 8 or ib < 1 or ib >= d or d > bm_bits) return error.Corrupt;
    var c = Context{ .device = device, .scratch = scratch, .disk = disk, .index = undefined, .h = h, .bitmap = bitmap, .namesz = if ((flags & 1) != 0) 16 else if ((flags & 2) != 0) 64 else 32, .index_bytes = ib * device.block_size };

    // Index header can cross blocks only on unusual small geometries; use a
    // fixed local buffer and the common cross-block reader.
    var ih: [64]u8 = undefined;
    try readAt(&c, 0, ih[0..h]);
    c.index = try wire.decodeIndexHeader(ih[0..h], fixed);
    const x = c.index;
    const fcap_max: u32 = 65534;
    const ncap_max: u32 = if (fixed) 65535 else 65536;
    if (x.file_capacity > fcap_max or x.name_capacity > ncap_max or x.extent_capacity > 65535) return error.Corrupt;
    if (x.file_first_available > x.file_capacity or x.name_first_available > x.name_capacity or x.extent_first_available > x.extent_capacity) return error.Corrupt;
    if (x.file_first_available > 65534 or x.name_first_available > ncap_max or x.extent_first_available > 65535) return error.Corrupt;
    const offsets = [_]u32{ x.file_offset, x.name_offset, x.extent_offset };
    const caps = [_]u32{ x.file_capacity, x.name_capacity, x.extent_capacity };
    const sizes = [_]u32{ 12, c.namesz, 64 };
    const aligns = [_]u32{ if (h > 32) h else 32, if (h > 64) h else 64, if (h > 64) h else 64 };
    for (offsets, caps, sizes, aligns, 0..) |off, cap, size, alignment, i| {
        if (off < h or off > c.index_bytes or off % alignment != 0) return error.Corrupt;
        const end = @as(u64, off) + @as(u64, cap) * size;
        if (end > c.index_bytes) return error.Corrupt;
        if (cap != 0) for (offsets, caps, sizes, 0..) |other_off, other_cap, other_size, j| {
            if (i == j or other_cap == 0) continue;
            const other_end = @as(u64, other_off) + @as(u64, other_cap) * other_size;
            if (@as(u64, off) < other_end and @as(u64, other_off) < end) return error.Corrupt;
        };
    }
    if (fixed and x.file_offset != 32) return error.Corrupt;

    // The file table is packed; validating each entry and rescanning earlier
    // entries replaces a file-ID set while keeping workspace constant.
    var fi: u32 = 0;
    while (fi < x.file_first_available) : (fi += 1) {
        const f = try fileAt(&c, fi);
        if (f.id < 2) return error.Corrupt;
        var prev: u32 = 0;
        while (prev < fi) : (prev += 1) if ((try fileAt(&c, prev)).id == f.id) return error.Corrupt;
        if (f.name_index >= x.name_capacity) return error.Corrupt;
        if (isDirectory(f) and f.first_extent != wire.no_link) return error.Corrupt;
        const par = try parentOf(&c, f);
        if (par == f.id) return error.Corrupt;
        if (par != 0) {
            const pf = (try findFile(&c, par)) orelse return error.Corrupt;
            if (!isDirectory(pf)) return error.Corrupt;
        }
        const nm = try nameAt(&c, f.name_index);
        if (nm[0] == 0) return error.Corrupt;
        const nl = nameLen(&nm, c.namesz);
        if (nl == 0) return error.Corrupt;
        for (0..@as(usize, @intCast(nl))) |i| if (nm[i] < 0x20 or nm[i] > 0x7e) return error.Corrupt;
        // Every parent chain is bounded by the live file count; a repeated ID
        // encountered during this walk proves a cycle without a visited set.
        var ancestor = par;
        var depth: u32 = 0;
        while (ancestor != 0) : (depth += 1) {
            if (depth >= x.file_first_available) return error.Corrupt;
            const af = (try findFile(&c, ancestor)) orelse return error.Corrupt;
            ancestor = try parentOf(&c, af);
        }
        // Repeated sibling scans enforce both exclusive name-slot ownership
        // and decoded-name uniqueness without storing maps.
        var fj: u32 = 0;
        while (fj < x.file_first_available) : (fj += 1) {
            if (fj == fi) continue;
            const g = try fileAt(&c, fj);
            if (g.name_index == f.name_index) return error.Corrupt;
            if (try parentOf(&c, g) == par) {
                const gn = try nameAt(&c, g.name_index);
                const gl = nameLen(&gn, c.namesz);
                if (nl == gl and std.mem.eql(u8, nm[0..@intCast(nl)], gn[0..@intCast(gl)])) return error.Corrupt;
            }
        }
        if (isDirectory(f)) {
            if (f.first_extent != wire.no_link) return error.Corrupt;
            var kids: u32 = 0;
            var fj2: u32 = 0;
            while (fj2 < x.file_first_available) : (fj2 += 1) {
                if (try parentOf(&c, try fileAt(&c, fj2)) == f.id) kids += 1;
            }
            if (kids != f.size_or_children) return error.Corrupt;
        } else {
            var allocated: u64 = 0;
            var p = f.first_extent;
            var prev_page: u16 = wire.no_link;
            var ordinal: u32 = 1;
            var pg_count: u32 = 0;
            while (p != wire.no_link) : (pg_count += 1) {
                if (p >= x.extent_capacity or pg_count >= x.extent_capacity) return error.Corrupt;
                const pg = try pageAt(&c, p);
                if (pg.ordinal != ordinal or pg.previous != prev_page) return error.Corrupt;
                var used: u32 = 0;
                var empty_seen = false;
                for (pg.entries) |e| {
                    if (e.block_count == 0) {
                        empty_seen = true;
                        continue;
                    }
                    if (empty_seen or e.start_block <= disk.index_blocks or @as(u64, e.start_block) + e.block_count > d) return error.Corrupt;
                    used += 1;
                    allocated += e.block_count;
                }
                if (pg.next != wire.no_link and used != 7) return error.Corrupt;
                if (pg.next != wire.no_link and pg.next >= x.extent_capacity) return error.Corrupt;
                prev_page = p;
                p = pg.next;
                ordinal += 1;
            }
            const required_blocks = (@as(u64, f.size_or_children) + device.block_size - 1) / device.block_size;
            if (allocated < required_blocks) return error.Corrupt;
        }
    }

    try extentsDoNotOverlap(&c);

    // Each in-use name/page must have one owner; a repeated owner scan avoids
    // in-memory bitsets even for maximum-capacity tables.
    var ni: u32 = 0;
    var lowest_name: ?u32 = null;
    while (ni < x.name_capacity) : (ni += 1) {
        const nm = try nameAt(&c, ni);
        if (nm[0] == 0) {
            if (lowest_name == null) lowest_name = ni;
            continue;
        }
        var owners: u32 = 0;
        fi = 0;
        while (fi < x.file_first_available) : (fi += 1) {
            if ((try fileAt(&c, fi)).name_index == ni) owners += 1;
        }
        if (owners != 1) return error.Corrupt;
    }
    if ((lowest_name orelse x.name_capacity) != x.name_first_available) return error.Corrupt;
    var ei: u32 = 0;
    var lowest_extent: ?u32 = null;
    while (ei < x.extent_capacity) : (ei += 1) {
        const pg = try pageAt(&c, ei);
        if (pg.ordinal == 0) {
            if (lowest_extent == null) lowest_extent = ei;
            continue;
        }
        var owners: u32 = 0;
        fi = 0;
        while (fi < x.file_first_available) : (fi += 1) {
            if (try chainContains(&c, try fileAt(&c, fi), @intCast(ei))) owners += 1;
        }
        if (owners != 1) return error.Corrupt;
    }
    if ((lowest_extent orelse x.extent_capacity) != x.extent_first_available) return error.Corrupt;

    // Compare every real bitmap bit to recomputed structure ownership. Index
    // blocks are always occupied; the nested extent scan catches all aliasing.
    var block: u32 = 0;
    while (block < device.block_count) : (block += 1) {
        const byte_index = bitmap + block / 8;
        const data = try rd(&c, 0);
        const bit = (data[@intCast(byte_index)] & (@as(u8, 1) << @intCast(block % 8))) != 0;
        var expected = block <= disk.index_blocks;
        if (!expected) expected = try blockReferenced(&c, block);
        if (bit != expected) return error.Corrupt;
    }
    var bit_index: u64 = d;
    while (bit_index < bm_bits) : (bit_index += 1) {
        const data = try rd(&c, 0);
        if ((data[@intCast(bitmap + bit_index / 8)] & (@as(u8, 1) << @intCast(bit_index % 8))) == 0) return error.Corrupt;
    }
    return .{ .disk = disk, .index = x, .header_size = @intCast(h), .bitmap_offset = @intCast(bitmap), .name_size = @intCast(c.namesz), .read_only = (flags & 8) != 0 };
}
