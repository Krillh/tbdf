//! A small, allocation-free reader and writer for TBDF1 disk images.
//!
//! The volume borrows the caller's scratch buffer and block device. It is not
//! reentrant: one operation at a time may use a given Volume.

const std = @import("std");
const io = @import("block_io.zig");
const layout = @import("layout.zig");
const wire = @import("wire.zig");
const validate_image = @import("validate.zig");

pub const BlockDevice = io.BlockDevice;
pub const Scratch = io.Scratch;

pub const Error = error{
    InvalidImage,
    UnsupportedFeature,
    InvalidInput,
    NotFound,
    AlreadyExists,
    NotDirectory,
    IsDirectory,
    ReadOnly,
    NoSpace,
    IdExhausted,
    BufferTooSmall,
    VolumeInvalidated,
};

pub const FileId = struct {
    value: u16,

    pub const root: FileId = .{ .value = 0 };
};

pub const FileKind = enum { regular, directory };

pub const FileInfo = struct {
    id: FileId,
    parent: FileId,
    kind: FileKind,
    details: union(enum) {
        regular_size: u32,
        direct_children: u32,
    },
    read_only: bool,
};

pub const NamedEntry = struct {
    info: FileInfo,
    name_length: usize,
};

pub const OpenInfo = struct {
    block_size: u32,
    block_count: u32,
    index_blocks: u16,
    feature_flags: u32,
    name_bytes: u8,
    read_only: bool,
};

pub const Volume = struct {
    device: BlockDevice,
    scratch: Scratch,
    checked: validate_image.Result,
    invalidated: bool = false,

    /// Opens only after a complete structural and ownership validation pass.
    /// The validation favors bounded RAM over I/O count and can rescan tables
    /// repeatedly on larger images.
    pub fn open(device: BlockDevice, scratch_bytes: []u8) anyerror!Volume {
        var scratch = try Scratch.init(scratch_bytes, device.block_size);
        const checked = validate_image.validate(device, &scratch) catch |err| {
            if (err == error.Corrupt) return error.InvalidImage;
            return err;
        };
        return .{ .device = device, .scratch = scratch, .checked = checked };
    }

    pub fn info(self: *const Volume) OpenInfo {
        return .{
            .block_size = self.device.block_size,
            .block_count = self.device.block_count,
            .index_blocks = self.checked.disk.index_blocks,
            .feature_flags = self.checked.disk.feature_flags,
            .name_bytes = self.checked.name_size,
            .read_only = self.checked.read_only or self.device.write_block == null,
        };
    }

    fn ready(self: *const Volume) Error!void {
        if (self.invalidated) return error.VolumeInvalidated;
    }

    fn writeBlockTracked(self: *Volume, block: u32) anyerror!void {
        const writer = self.device.write_block orelse return error.ReadOnly;
        writer(self.device.context, block, self.scratch.block(self.device.block_size)) catch |err| {
            self.invalidated = true;
            return err;
        };
    }

    fn writeIndexRange(self: *Volume, offset: u64, input: []const u8, index_blocks: u16) anyerror!void {
        const limit = @as(u64, index_blocks) * self.device.block_size;
        const end = std.math.add(u64, offset, input.len) catch return error.InvalidInput;
        if (end > limit) return error.InvalidInput;
        var copied: usize = 0;
        while (copied < input.len) {
            const absolute = offset + copied;
            const block_index: u32 = 1 + @as(u32, @intCast(absolute / self.device.block_size));
            const within: usize = @intCast(absolute % self.device.block_size);
            const block = try io.readBlock(self.device, &self.scratch, block_index);
            const amount = @min(input.len - copied, block.len - within);
            @memcpy(block[within .. within + amount], input[copied .. copied + amount]);
            try self.writeBlockTracked(block_index);
            copied += amount;
        }
    }

    const Table = enum { file, name, extent };

    const GrowthPlan = struct {
        old_index: wire.IndexHeader,
        new_index: wire.IndexHeader,
        old_blocks: u16,
        new_blocks: u16,
        old_offsets: [3]u32,
        old_capacities: [3]u32,
        grew: [3]bool = .{ false, false, false },
        moved: [3]bool = .{ false, false, false },
        moved_any: bool = false,
    };

    fn tablePosition(table: Table) usize {
        return switch (table) {
            .file => 0,
            .name => 1,
            .extent => 2,
        };
    }

    fn tableOffset(index: wire.IndexHeader, table: Table) u32 {
        return switch (table) {
            .file => index.file_offset,
            .name => index.name_offset,
            .extent => index.extent_offset,
        };
    }

    fn tableCapacity(index: wire.IndexHeader, table: Table) u32 {
        return switch (table) {
            .file => index.file_capacity,
            .name => index.name_capacity,
            .extent => index.extent_capacity,
        };
    }

    fn tableAvailable(index: wire.IndexHeader, table: Table) u32 {
        return switch (table) {
            .file => index.file_first_available,
            .name => index.name_first_available,
            .extent => index.extent_first_available,
        };
    }

    fn setTable(index: *wire.IndexHeader, table: Table, offset: u32, capacity: u32) void {
        switch (table) {
            .file => {
                index.file_offset = offset;
                index.file_capacity = capacity;
            },
            .name => {
                index.name_offset = offset;
                index.name_capacity = capacity;
            },
            .extent => {
                index.extent_offset = offset;
                index.extent_capacity = capacity;
            },
        }
    }

    fn setAvailable(index: *wire.IndexHeader, table: Table, value: u32) void {
        switch (table) {
            .file => index.file_first_available = value,
            .name => index.name_first_available = value,
            .extent => index.extent_first_available = value,
        }
    }

    fn tableSlotBytes(self: *const Volume, table: Table) u32 {
        return switch (table) {
            .file => 12,
            .name => self.checked.name_size,
            .extent => 64,
        };
    }

    fn tableMax(table: Table) u32 {
        return switch (table) {
            .file => 65534,
            .name => 65536,
            .extent => 65535,
        };
    }

    fn startGrowth(self: *Volume) GrowthPlan {
        const index = self.checked.index;
        return .{
            .old_index = index,
            .new_index = index,
            .old_blocks = self.checked.disk.index_blocks,
            .new_blocks = self.checked.disk.index_blocks,
            .old_offsets = .{ index.file_offset, index.name_offset, index.extent_offset },
            .old_capacities = .{ index.file_capacity, index.name_capacity, index.extent_capacity },
        };
    }

    fn reserveSlots(self: *Volume, plan: *GrowthPlan, table: Table, required: u32) Error!void {
        const capacity = tableCapacity(plan.new_index, table);
        if (capacity >= required) return;
        const max_capacity = tableMax(table);
        if (required > max_capacity) return error.NoSpace;
        var next = if (capacity == 0) @as(u32, 1) else capacity;
        while (next < required) {
            if (next > max_capacity / 2) {
                next = max_capacity;
                break;
            }
            next *= 2;
        }
        if (next < required) return error.NoSpace;

        const bytes = layout.mul(next, self.tableSlotBytes(table)) catch return error.NoSpace;
        const slot_bytes = @as(u64, self.tableSlotBytes(table));
        const old_offset = tableOffset(plan.new_index, table);
        const old_end = @as(u64, old_offset) + @as(u64, capacity) * slot_bytes;
        const extended_end = @as(u64, old_offset) + bytes;
        const index_limit = @as(u64, plan.new_blocks) * self.device.block_size;
        var destination: ?u64 = null;

        // Prefer extending the current allocation when its immediate gap is
        // large enough and no other capacity region occupies it.
        if (extended_end <= index_limit and self.tableRangeFree(plan.new_index, table, old_offset, extended_end)) {
            destination = old_offset;
        } else {
            // Reuse a free aligned gap inside the existing index before adding
            // blocks. Do not overlap the old source while copying the table.
            var candidate = @as(u64, if (table == .file) 64 else 64);
            while (candidate + bytes <= index_limit) : (candidate += 64) {
                if (candidate < old_end and @as(u64, old_offset) < candidate + bytes) continue;
                if (self.tableRangeFree(plan.new_index, table, candidate, candidate + bytes)) {
                    destination = candidate;
                    break;
                }
            }
        }

        if (destination) |offset| {
            setTable(&plan.new_index, table, @intCast(offset), next);
            plan.moved[tablePosition(table)] = offset != old_offset;
        } else {
            const alignment: u64 = 64;
            const current_end = @as(u64, plan.new_blocks) * self.device.block_size;
            const offset = layout.alignForward(current_end, alignment) catch return error.NoSpace;
            const end = layout.add(offset, bytes) catch return error.NoSpace;
            const block_size = @as(u64, self.device.block_size);
            const new_blocks = (end + block_size - 1) / block_size;
            if (new_blocks > std.math.maxInt(u16) or new_blocks >= self.device.block_count) return error.NoSpace;
            setTable(&plan.new_index, table, @intCast(offset), next);
            plan.new_blocks = @intCast(new_blocks);
            plan.moved[tablePosition(table)] = true;
        }
        if (table != .file and tableAvailable(plan.old_index, table) == capacity)
            setAvailable(&plan.new_index, table, capacity);
        plan.grew[tablePosition(table)] = true;
        plan.moved_any = true;
    }

    fn tableRangeFree(self: *const Volume, index: wire.IndexHeader, excluded: Table, start: u64, end: u64) bool {
        if (start < self.checked.header_size or end < start) return false;
        for ([_]Table{ .file, .name, .extent }) |table| {
            if (table == excluded or tableCapacity(index, table) == 0) continue;
            const other_start = @as(u64, tableOffset(index, table));
            const other_end = other_start + @as(u64, tableCapacity(index, table)) * self.tableSlotBytes(table);
            if (start < other_end and other_start < end) return false;
        }
        return true;
    }

    fn checkedPlanSpace(self: *Volume, plan: GrowthPlan, additional_data_blocks: u64) anyerror!void {
        const allocated = try self.allocatedBlockCount();
        const required = @as(u64, plan.new_blocks) + 1 + allocated + additional_data_blocks;
        if (required > self.device.block_count) return error.NoSpace;
    }

    fn allocatedBlockCount(self: *Volume) anyerror!u64 {
        var total: u64 = 0;
        var slot: u32 = 0;
        while (slot < self.checked.index.extent_capacity) : (slot += 1) {
            const page = try self.extentPage(@intCast(slot));
            if (page.ordinal == 0) continue;
            for (page.entries) |extent| total += extent.block_count;
        }
        return total;
    }

    fn bitmapBit(self: *Volume, block: u32) anyerror!bool {
        const bytes = try io.readBlock(self.device, &self.scratch, 0);
        const bitmap_offset: usize = self.checked.bitmap_offset;
        const byte_index = bitmap_offset + block / 8;
        return bytes[byte_index] & (@as(u8, 1) << @intCast(block % 8)) != 0;
    }

    fn countBefore(self: *Volume, block: u32, old_index_blocks: u16) anyerror!u64 {
        var count: u64 = 0;
        var current: u32 = @as(u32, old_index_blocks) + 1;
        while (current < block) : (current += 1) {
            if (try self.bitmapBit(current)) count += 1;
        }
        return count;
    }

    fn compactData(self: *Volume, new_index_blocks: u16) anyerror!u64 {
        const old_index_blocks = self.checked.disk.index_blocks;
        const first_data = @as(u32, old_index_blocks) + 1;
        var count: u64 = 0;
        var block = first_data;
        while (block < self.device.block_count) : (block += 1) {
            if (try self.bitmapBit(block)) count += 1;
        }

        // First move right-shifting blocks from the end toward the front. Then
        // move left-shifting blocks in the opposite direction. The mapping is
        // monotone, so either pass preserves every not-yet-read source block.
        var seen: u64 = 0;
        var reverse = self.device.block_count;
        while (reverse > first_data) {
            reverse -= 1;
            if (!(try self.bitmapBit(reverse))) continue;
            const destination64 = @as(u64, new_index_blocks) + count - seen;
            seen += 1;
            if (destination64 <= reverse) continue;
            _ = try io.readBlock(self.device, &self.scratch, reverse);
            const destination: u32 = @intCast(destination64);
            try self.writeBlockTracked(destination);
        }

        seen = 0;
        block = first_data;
        while (block < self.device.block_count) : (block += 1) {
            if (!(try self.bitmapBit(block))) continue;
            const destination64 = @as(u64, new_index_blocks) + 1 + seen;
            seen += 1;
            if (destination64 >= block) continue;
            _ = try io.readBlock(self.device, &self.scratch, block);
            const destination: u32 = @intCast(destination64);
            try self.writeBlockTracked(destination);
        }

        // The bitmap still describes old physical locations. Use it to map
        // each old extent start, then update the authoritative old extent table
        // before any table copying changes its location.
        var page_index: u32 = 0;
        while (page_index < self.checked.index.extent_capacity) : (page_index += 1) {
            const page_offset = @as(u64, self.checked.index.extent_offset) + @as(u64, page_index) * 64;
            const raw = self.scratch.staging(self.device.block_size)[0..64];
            try self.indexBytes(page_offset, raw);
            var page = try wire.decodeExtentPage(raw);
            if (page.ordinal == 0) continue;
            for (&page.entries) |*extent| {
                if (extent.block_count == 0) continue;
                const rank = try self.countBefore(extent.start_block, old_index_blocks);
                extent.start_block = @intCast(@as(u64, new_index_blocks) + 1 + rank);
            }
            try wire.encodeExtentPage(raw, page);
            try self.writeIndexRange(page_offset, raw, old_index_blocks);
        }
        return count;
    }

    fn copyGrownTable(self: *Volume, plan: GrowthPlan, table: Table) anyerror!void {
        const position = tablePosition(table);
        if (!plan.grew[position]) return;
        const source = plan.old_offsets[position];
        const destination = tableOffset(plan.new_index, table);
        const old_capacity = plan.old_capacities[position];
        const slot_bytes = self.tableSlotBytes(table);
        if (plan.moved[position]) {
            var slot: u32 = 0;
            while (slot < old_capacity) : (slot += 1) {
                const stage = self.scratch.staging(self.device.block_size)[0..slot_bytes];
                try self.indexBytes(@as(u64, source) + @as(u64, slot) * slot_bytes, stage);
                try self.writeIndexRange(@as(u64, destination) + @as(u64, slot) * slot_bytes, stage, plan.new_blocks);
            }
        }
        var slot = old_capacity;
        while (slot < tableCapacity(plan.new_index, table)) : (slot += 1) {
            const stage = self.scratch.staging(self.device.block_size)[0..slot_bytes];
            @memset(stage, 0);
            try self.writeIndexRange(@as(u64, destination) + @as(u64, slot) * slot_bytes, stage, plan.new_blocks);
        }
    }

    fn writeIndexHeader(self: *Volume) anyerror!void {
        const size: usize = self.checked.header_size;
        const stage = self.scratch.staging(self.device.block_size)[0..size];
        @memset(stage, 0);
        try wire.encodeIndexHeader(stage, self.checked.index, false);
        try self.writeIndexRange(0, stage, self.checked.disk.index_blocks);
    }

    fn executeGrowth(self: *Volume, plan: GrowthPlan, move_data: bool) anyerror!void {
        if (move_data) _ = try self.compactData(plan.new_blocks);
        try self.copyGrownTable(plan, .file);
        try self.copyGrownTable(plan, .name);
        try self.copyGrownTable(plan, .extent);
        self.checked.index = plan.new_index;
        self.checked.disk.index_blocks = plan.new_blocks;
        try self.writeIndexHeader();
    }

    fn rebuildBitmap(self: *Volume) anyerror!void {
        const block0 = try io.readBlock(self.device, &self.scratch, 0);
        try wire.encodeDiskHeader(block0, self.checked.disk, false);
        const offset: usize = self.checked.bitmap_offset;
        @memset(block0[offset..], 0xFF);
        var block = @as(u32, self.checked.disk.index_blocks) + 1;
        while (block < self.device.block_count) : (block += 1) {
            const byte_index = offset + block / 8;
            block0[byte_index] &= ~(@as(u8, 1) << @intCast(block % 8));
        }
        try self.writeBlockTracked(0);

        var page_index: u32 = 0;
        while (page_index < self.checked.index.extent_capacity) : (page_index += 1) {
            const page = try self.extentPage(@intCast(page_index));
            if (page.ordinal == 0) continue;
            const bitmap = try io.readBlock(self.device, &self.scratch, 0);
            for (page.entries) |extent| {
                var data_block = extent.start_block;
                const end = @as(u64, extent.start_block) + extent.block_count;
                while (@as(u64, data_block) < end) : (data_block += 1) {
                    const byte_index = offset + data_block / 8;
                    bitmap[byte_index] |= @as(u8, 1) << @intCast(data_block % 8);
                }
            }
            try self.writeBlockTracked(0);
        }
    }

    fn writable(self: *Volume) Error!void {
        try self.ready();
        if (self.checked.disk.feature_flags != 0) return error.ReadOnly;
        if (self.device.write_block == null) return error.ReadOnly;
    }

    fn validateName(self: *const Volume, name: []const u8) Error!void {
        if (name.len == 0 or name.len > self.checked.name_size) return error.InvalidInput;
        for (name) |byte| if (byte < 0x20 or byte > 0x7E) return error.InvalidInput;
    }

    fn findFileSlot(self: *Volume, id: FileId) anyerror!?u32 {
        var slot: u32 = 0;
        while (slot < self.checked.index.file_first_available) : (slot += 1) {
            if ((try self.fileAt(slot)).id == id.value) return slot;
        }
        return null;
    }

    fn writeFileSlot(self: *Volume, slot: u32, entry: wire.FileEntry) anyerror!void {
        const stage = self.scratch.staging(self.device.block_size)[0..wire.file_entry_bytes];
        try wire.encodeFileEntry(stage, entry);
        const offset = @as(u64, self.checked.index.file_offset) + @as(u64, slot) * wire.file_entry_bytes;
        try self.writeIndexRange(offset, stage, self.checked.disk.index_blocks);
    }

    fn planAppendExtentPage(self: *Volume, plan: *GrowthPlan, file: wire.FileEntry) anyerror!bool {
        var needs_page = file.first_extent == wire.no_link;
        if (!needs_page) {
            var page_index = file.first_extent;
            var last: wire.ExtentPage = undefined;
            var guard: u32 = 0;
            while (true) {
                if (page_index >= self.checked.index.extent_capacity or guard >= self.checked.index.extent_capacity)
                    return error.InvalidImage;
                last = try self.extentPage(page_index);
                guard += 1;
                if (last.next == wire.no_link) break;
                page_index = last.next;
            }
            var used: u32 = 0;
            for (last.entries) |extent| if (extent.block_count != 0) {
                used += 1;
            };
            needs_page = used == 7;
        }
        if (needs_page and plan.new_index.extent_first_available == plan.new_index.extent_capacity) {
            try self.reserveSlots(plan, .extent, plan.new_index.extent_capacity + 1);
        }
        return needs_page;
    }

    fn isLastExtentAtTail(self: *Volume, entry: wire.FileEntry, new_index_blocks: u16, total_data: u64) anyerror!bool {
        if (entry.first_extent == wire.no_link) return false;
        var page_index = entry.first_extent;
        var last_page: wire.ExtentPage = undefined;
        var guard: u32 = 0;
        while (true) {
            if (guard >= self.checked.index.extent_capacity) return error.InvalidImage;
            last_page = try self.extentPage(page_index);
            guard += 1;
            if (last_page.next == wire.no_link) break;
            page_index = last_page.next;
        }
        var last_extent: ?wire.Extent = null;
        for (last_page.entries) |extent| if (extent.block_count != 0) {
            last_extent = extent;
        };
        const extent = last_extent orelse return false;
        const rank = try self.countBefore(extent.start_block, self.checked.disk.index_blocks);
        const mapped_end = @as(u64, new_index_blocks) + 1 + rank + extent.block_count;
        return mapped_end == @as(u64, new_index_blocks) + 1 + total_data;
    }

    fn nextNameSlot(self: *Volume, used_slot: u32) anyerror!u32 {
        var candidate = used_slot + 1;
        while (candidate < self.checked.index.name_capacity) : (candidate += 1) {
            const name = try self.rawNameAt(candidate);
            if (name[0] == 0) return candidate;
        }
        return self.checked.index.name_capacity;
    }

    fn writeNameSlot(self: *Volume, slot: u32, name: []const u8) anyerror!void {
        const size: usize = self.checked.name_size;
        var stage = self.scratch.staging(self.device.block_size)[0..size];
        @memset(stage, 0);
        @memcpy(stage[0..name.len], name);
        const offset = @as(u64, self.checked.index.name_offset) + @as(u64, slot) * size;
        try self.writeIndexRange(offset, stage, self.checked.disk.index_blocks);
    }

    fn writeExtentSlot(self: *Volume, slot: u16, page: wire.ExtentPage) anyerror!void {
        const offset = @as(u64, self.checked.index.extent_offset) + @as(u64, slot) * wire.extent_page_bytes;
        const stage = self.scratch.staging(self.device.block_size)[0..wire.extent_page_bytes];
        try self.indexBytes(offset, stage);
        try wire.encodeExtentPage(stage, page);
        try self.writeIndexRange(offset, stage, self.checked.disk.index_blocks);
    }

    fn allocateFileId(self: *Volume, kind: FileKind) anyerror!FileId {
        var candidate: u32 = if (kind == .directory) 2 else 3;
        while (candidate <= std.math.maxInt(u16)) : (candidate += 2) {
            if ((try self.entryById(.{ .value = @intCast(candidate) })) == null)
                return .{ .value = @intCast(candidate) };
        }
        return error.IdExhausted;
    }

    fn fileAllocatedBlocks(self: *Volume, entry: wire.FileEntry) anyerror!u64 {
        var total: u64 = 0;
        var page_index = entry.first_extent;
        var guard: u32 = 0;
        while (page_index != wire.no_link) {
            if (guard >= self.checked.index.extent_capacity) return error.InvalidImage;
            const page = try self.extentPage(page_index);
            for (page.entries) |extent| total += extent.block_count;
            page_index = page.next;
            guard += 1;
        }
        return total;
    }

    fn physicalAt(self: *Volume, entry: wire.FileEntry, logical_offset: u64) anyerror!struct { block: u32, byte: usize } {
        var logical: u64 = 0;
        var page_index = entry.first_extent;
        var guard: u32 = 0;
        while (page_index != wire.no_link) {
            if (guard >= self.checked.index.extent_capacity) return error.InvalidImage;
            const page = try self.extentPage(page_index);
            for (page.entries) |extent| {
                if (extent.block_count == 0) break;
                const extent_bytes = @as(u64, extent.block_count) * self.device.block_size;
                if (logical_offset < logical + extent_bytes) {
                    const within = logical_offset - logical;
                    return .{
                        .block = extent.start_block + @as(u32, @intCast(within / self.device.block_size)),
                        .byte = @intCast(within % self.device.block_size),
                    };
                }
                logical += extent_bytes;
            }
            page_index = page.next;
            guard += 1;
        }
        return error.InvalidImage;
    }

    fn writeData(self: *Volume, entry: wire.FileEntry, offset: u64, input: []const u8, zero_length: usize) anyerror!void {
        var position = offset;
        var consumed: usize = 0;
        const total = if (zero_length != 0) zero_length else input.len;
        while (consumed < total) {
            const physical = try self.physicalAt(entry, position);
            const block_data = try io.readBlock(self.device, &self.scratch, physical.block);
            const amount = @min(total - consumed, block_data.len - physical.byte);
            if (zero_length != 0) {
                @memset(block_data[physical.byte .. physical.byte + amount], 0);
            } else {
                @memcpy(block_data[physical.byte .. physical.byte + amount], input[consumed .. consumed + amount]);
            }
            try self.writeBlockTracked(physical.block);
            position += amount;
            consumed += amount;
        }
    }

    fn appendExtent(self: *Volume, id: FileId, additional_blocks: u32, merge: bool) anyerror!void {
        const file_slot = (try self.findFileSlot(id)) orelse return error.InvalidImage;
        var entry = try self.fileAt(file_slot);
        const tail_start = @as(u64, self.checked.disk.index_blocks) + 1 + try self.allocatedBlockCount();
        if (merge) {
            var page_index = entry.first_extent;
            var last_page_index: u16 = wire.no_link;
            var last_page: wire.ExtentPage = undefined;
            while (page_index != wire.no_link) {
                last_page_index = page_index;
                last_page = try self.extentPage(page_index);
                page_index = last_page.next;
            }
            var last_entry: ?usize = null;
            for (last_page.entries, 0..) |extent, index| if (extent.block_count != 0) {
                last_entry = index;
            };
            const entry_index = last_entry orelse return error.InvalidImage;
            last_page.entries[entry_index].block_count += additional_blocks;
            try self.writeExtentSlot(last_page_index, last_page);
            return;
        }

        var page_index = entry.first_extent;
        var last_page_index: u16 = wire.no_link;
        var last_page: wire.ExtentPage = undefined;
        while (page_index != wire.no_link) {
            last_page_index = page_index;
            last_page = try self.extentPage(page_index);
            page_index = last_page.next;
        }
        var used: usize = 0;
        if (last_page_index != wire.no_link) {
            while (used < last_page.entries.len and last_page.entries[used].block_count != 0) : (used += 1) {}
        }
        const new_page = last_page_index == wire.no_link or used == 7;
        if (new_page) {
            const new_page_index = self.checked.index.extent_first_available;
            if (new_page_index >= self.checked.index.extent_capacity) return error.InvalidImage;
            const ordinal: u32 = if (last_page_index == wire.no_link) 1 else @as(u32, last_page.ordinal) + 1;
            if (ordinal > std.math.maxInt(u16)) return error.NoSpace;
            var page = wire.ExtentPage{
                .ordinal = @intCast(ordinal),
                .next = wire.no_link,
                .previous = last_page_index,
                .entries = @splat(.{ .start_block = 0, .block_count = 0 }),
            };
            page.entries[0] = .{ .start_block = @intCast(tail_start), .block_count = additional_blocks };
            try self.writeExtentSlot(@intCast(new_page_index), page);
            if (last_page_index == wire.no_link) {
                entry.first_extent = @intCast(new_page_index);
                try self.writeFileSlot(file_slot, entry);
            } else {
                last_page.next = @intCast(new_page_index);
                try self.writeExtentSlot(last_page_index, last_page);
            }
            self.checked.index.extent_first_available = try self.nextUnusedExtent(@intCast(new_page_index));
        } else {
            last_page.entries[used] = .{ .start_block = @intCast(tail_start), .block_count = additional_blocks };
            try self.writeExtentSlot(last_page_index, last_page);
        }
    }

    fn nextUnusedExtent(self: *Volume, used_slot: u16) anyerror!u32 {
        var slot: u32 = @as(u32, used_slot) + 1;
        while (slot < self.checked.index.extent_capacity) : (slot += 1) {
            const page = try self.extentPage(@intCast(slot));
            if (page.ordinal == 0) return slot;
        }
        return self.checked.index.extent_capacity;
    }

    fn finishMutation(self: *Volume) anyerror!void {
        try self.writeIndexHeader();
        try self.rebuildBitmap();
    }

    /// Writes at an existing offset or exactly at EOF. The complete request is
    /// space-checked before the first block write.
    pub fn writeAt(self: *Volume, id: FileId, offset: u64, input: []const u8) anyerror!usize {
        try self.writable();
        var mutation_started = false;
        errdefer {
            if (mutation_started) self.invalidated = true;
        }
        const file_slot = (try self.findFileSlot(id)) orelse return error.NotFound;
        const old_entry = try self.fileAt(file_slot);
        if (old_entry.id & 1 == 0) return error.IsDirectory;
        const old_size = @as(u64, old_entry.size_or_children);
        if (offset > old_size) return error.InvalidInput;
        if (input.len == 0) return 0;
        const end = std.math.add(u64, offset, input.len) catch return error.InvalidInput;
        if (end > std.math.maxInt(u32)) return error.InvalidInput;
        const new_size = @max(old_size, end);
        const required_blocks = (new_size + self.device.block_size - 1) / self.device.block_size;
        const allocated = try self.fileAllocatedBlocks(old_entry);
        const additional = if (required_blocks > allocated) required_blocks - allocated else 0;

        var plan = self.startGrowth();
        var merge = false;
        if (additional != 0) {
            const total_allocated = try self.allocatedBlockCount();
            merge = try self.isLastExtentAtTail(old_entry, plan.new_blocks, total_allocated);
            if (!merge) _ = try self.planAppendExtentPage(&plan, old_entry);
        }
        try self.checkedPlanSpace(plan, additional);
        mutation_started = true;
        if (plan.new_blocks != plan.old_blocks or additional != 0) {
            self.executeGrowth(plan, true) catch |err| {
                self.invalidated = true;
                return err;
            };
        }
        if (additional != 0) self.appendExtent(id, @intCast(additional), merge) catch |err| {
            self.invalidated = true;
            return err;
        };

        const current_slot = (try self.findFileSlot(id)) orelse return error.InvalidImage;
        var current_entry = try self.fileAt(current_slot);
        self.writeData(current_entry, offset, input, 0) catch |err| {
            self.invalidated = true;
            return err;
        };
        if (new_size != old_size) {
            current_entry.size_or_children = @intCast(new_size);
            self.writeFileSlot(current_slot, current_entry) catch |err| {
                self.invalidated = true;
                return err;
            };
        }
        self.finishMutation() catch |err| {
            self.invalidated = true;
            return err;
        };
        return input.len;
    }

    /// Changes a file's logical size. Growth writes zeros before publishing the
    /// new size; shrinking drops trailing blocks and releases empty extent pages.
    pub fn resize(self: *Volume, id: FileId, new_size: u64) anyerror!void {
        try self.writable();
        var mutation_started = false;
        errdefer {
            if (mutation_started) self.invalidated = true;
        }
        if (new_size > std.math.maxInt(u32)) return error.InvalidInput;
        const file_slot = (try self.findFileSlot(id)) orelse return error.NotFound;
        const old_entry = try self.fileAt(file_slot);
        if (old_entry.id & 1 == 0) return error.IsDirectory;
        const old_size = @as(u64, old_entry.size_or_children);
        if (new_size == old_size) return;

        if (new_size < old_size) {
            mutation_started = true;
            self.shrinkFile(old_entry, @intCast(new_size)) catch |err| {
                self.invalidated = true;
                return err;
            };
            return;
        }

        const required_blocks = (new_size + self.device.block_size - 1) / self.device.block_size;
        const allocated = try self.fileAllocatedBlocks(old_entry);
        const additional = if (required_blocks > allocated) required_blocks - allocated else 0;
        var plan = self.startGrowth();
        var merge = false;
        if (additional != 0) {
            const total_allocated = try self.allocatedBlockCount();
            merge = try self.isLastExtentAtTail(old_entry, plan.new_blocks, total_allocated);
            if (!merge) _ = try self.planAppendExtentPage(&plan, old_entry);
        }
        try self.checkedPlanSpace(plan, additional);
        mutation_started = true;
        if (plan.new_blocks != plan.old_blocks or additional != 0) {
            self.executeGrowth(plan, true) catch |err| {
                self.invalidated = true;
                return err;
            };
        }
        if (additional != 0) self.appendExtent(id, @intCast(additional), merge) catch |err| {
            self.invalidated = true;
            return err;
        };

        const current_slot = (try self.findFileSlot(id)) orelse return error.InvalidImage;
        var current_entry = try self.fileAt(current_slot);
        self.writeData(current_entry, old_size, &.{}, @intCast(new_size - old_size)) catch |err| {
            self.invalidated = true;
            return err;
        };
        current_entry.size_or_children = @intCast(new_size);
        self.writeFileSlot(current_slot, current_entry) catch |err| {
            self.invalidated = true;
            return err;
        };
        self.finishMutation() catch |err| {
            self.invalidated = true;
            return err;
        };
    }

    fn shrinkFile(self: *Volume, original: wire.FileEntry, new_size: u32) anyerror!void {
        const keep_blocks = (@as(u64, new_size) + self.device.block_size - 1) / self.device.block_size;
        var remaining = keep_blocks;
        var page_index = original.first_extent;
        var previous_kept: u16 = wire.no_link;
        var first_kept: u16 = wire.no_link;
        var guard: u32 = 0;
        while (page_index != wire.no_link) {
            if (guard >= self.checked.index.extent_capacity) return error.InvalidImage;
            const page = try self.extentPage(page_index);
            const next = page.next;
            var updated = page;
            for (&updated.entries) |*extent| {
                if (extent.block_count == 0) continue;
                if (remaining >= extent.block_count) {
                    remaining -= extent.block_count;
                } else if (remaining != 0) {
                    extent.block_count = @intCast(remaining);
                    remaining = 0;
                } else {
                    extent.* = .{ .start_block = 0, .block_count = 0 };
                }
            }
            var has_used = false;
            for (updated.entries) |extent| if (extent.block_count != 0) {
                has_used = true;
            };
            if (has_used) {
                if (first_kept == wire.no_link) first_kept = page_index;
                previous_kept = page_index;
                if (updated.next != next) return error.InvalidImage;
                try self.writeExtentSlot(page_index, updated);
            } else {
                updated.ordinal = 0;
                updated.next = wire.no_link;
                updated.previous = wire.no_link;
                for (&updated.entries) |*extent| extent.* = .{ .start_block = 0, .block_count = 0 };
                try self.writeExtentSlot(page_index, updated);
                self.checked.index.extent_first_available = @min(self.checked.index.extent_first_available, page_index);
                if (previous_kept != wire.no_link) {
                    var previous_page = try self.extentPage(previous_kept);
                    previous_page.next = wire.no_link;
                    try self.writeExtentSlot(previous_kept, previous_page);
                }
            }
            page_index = next;
            guard += 1;
        }
        const slot = (try self.findFileSlot(.{ .value = original.id })) orelse return error.InvalidImage;
        var entry = try self.fileAt(slot);
        entry.first_extent = first_kept;
        entry.size_or_children = new_size;
        try self.writeFileSlot(slot, entry);
        try self.finishMutation();
    }

    /// Creates a file or directory under `parent`.
    pub fn create(self: *Volume, parent: FileId, name: []const u8, kind: FileKind) anyerror!FileInfo {
        try self.writable();
        var mutation_started = false;
        errdefer {
            if (mutation_started) self.invalidated = true;
        }
        try self.validateName(name);
        const parent_info = try self.stat(parent);
        if (parent_info.kind != .directory) return error.NotDirectory;
        if (try self.lookup(parent, name) != null) return error.AlreadyExists;
        const id = try self.allocateFileId(kind);

        var plan = self.startGrowth();
        if (plan.new_index.file_first_available == plan.new_index.file_capacity)
            try self.reserveSlots(&plan, .file, plan.new_index.file_first_available + 1);
        if (plan.new_index.name_first_available == plan.new_index.name_capacity)
            try self.reserveSlots(&plan, .name, plan.new_index.name_first_available + 1);
        try self.checkedPlanSpace(plan, 0);

        mutation_started = true;
        self.executeGrowth(plan, plan.new_blocks != plan.old_blocks) catch |err| {
            self.invalidated = true;
            return err;
        };

        const name_index = self.checked.index.name_first_available;
        const name_next = self.nextNameSlot(name_index) catch |err| {
            self.invalidated = true;
            return err;
        };
        const file_slot = self.checked.index.file_first_available;
        self.writeNameSlot(name_index, name) catch |err| {
            self.invalidated = true;
            return err;
        };
        self.checked.index.name_first_available = name_next;
        self.checked.index.file_first_available += 1;
        const new_entry = wire.FileEntry{
            .id = id.value,
            .parent_or_flags = parent.value,
            .name_index = @intCast(name_index),
            .first_extent = wire.no_link,
            .size_or_children = 0,
        };
        self.writeFileSlot(file_slot, new_entry) catch |err| {
            self.invalidated = true;
            return err;
        };
        if (parent.value != 0) {
            const parent_slot = (try self.findFileSlot(parent)) orelse return error.InvalidImage;
            var parent_entry = try self.fileAt(parent_slot);
            parent_entry.size_or_children += 1;
            self.writeFileSlot(parent_slot, parent_entry) catch |err| {
                self.invalidated = true;
                return err;
            };
        }
        self.writeIndexHeader() catch |err| {
            self.invalidated = true;
            return err;
        };
        self.rebuildBitmap() catch |err| {
            self.invalidated = true;
            return err;
        };
        return .{
            .id = id,
            .parent = parent,
            .kind = kind,
            .details = if (kind == .directory) .{ .direct_children = 0 } else .{ .regular_size = 0 },
            .read_only = false,
        };
    }

    /// Deletes a leaf file or an empty directory.
    pub fn delete(self: *Volume, id: FileId) anyerror!void {
        try self.writable();
        var mutation_started = false;
        errdefer {
            if (mutation_started) self.invalidated = true;
        }
        if (id.value < 2) return error.InvalidInput;
        const removed_slot = (try self.findFileSlot(id)) orelse return error.NotFound;
        const entry = try self.fileAt(removed_slot);
        const entry_info = try self.fileInfo(entry);
        if (entry_info.kind == .directory and entry.size_or_children != 0) return error.InvalidInput;
        const last_slot = self.checked.index.file_first_available - 1;
        const moved_entry: ?wire.FileEntry = if (removed_slot != last_slot) try self.fileAt(last_slot) else null;
        var parent_slot: ?u32 = null;
        var updated_parent: ?wire.FileEntry = null;
        if (entry_info.parent.value != 0) {
            parent_slot = (try self.findFileSlot(entry_info.parent)) orelse return error.InvalidImage;
            var parent_entry = try self.fileAt(parent_slot.?);
            if (parent_entry.size_or_children == 0) return error.InvalidImage;
            parent_entry.size_or_children -= 1;
            updated_parent = parent_entry;
        }

        const name_offset = @as(u64, self.checked.index.name_offset) + @as(u64, entry.name_index) * self.checked.name_size;
        const zeros = self.scratch.staging(self.device.block_size)[0..self.checked.name_size];
        @memset(zeros, 0);
        mutation_started = true;
        self.writeIndexRange(name_offset, zeros, self.checked.disk.index_blocks) catch |err| {
            self.invalidated = true;
            return err;
        };
        self.checked.index.name_first_available = @min(self.checked.index.name_first_available, entry.name_index);

        var page_index = entry.first_extent;
        while (page_index != wire.no_link) {
            const page = self.extentPage(page_index) catch |err| {
                self.invalidated = true;
                return err;
            };
            const next = page.next;
            var empty = page;
            empty.ordinal = 0;
            empty.next = wire.no_link;
            empty.previous = wire.no_link;
            for (&empty.entries) |*extent| extent.* = .{ .start_block = 0, .block_count = 0 };
            self.writeExtentSlot(page_index, empty) catch |err| {
                self.invalidated = true;
                return err;
            };
            self.checked.index.extent_first_available = @min(self.checked.index.extent_first_available, page_index);
            page_index = next;
        }

        if (moved_entry) |last_entry| self.writeFileSlot(removed_slot, last_entry) catch |err| {
            self.invalidated = true;
            return err;
        };
        var empty_file: [wire.file_entry_bytes]u8 = @splat(0);
        const file_offset = @as(u64, self.checked.index.file_offset) + @as(u64, last_slot) * wire.file_entry_bytes;
        self.writeIndexRange(file_offset, &empty_file, self.checked.disk.index_blocks) catch |err| {
            self.invalidated = true;
            return err;
        };
        self.checked.index.file_first_available = last_slot;

        if (parent_slot) |old_parent_slot| {
            const destination = if (old_parent_slot == last_slot and removed_slot != last_slot) removed_slot else old_parent_slot;
            self.writeFileSlot(destination, updated_parent.?) catch |err| {
                self.invalidated = true;
                return err;
            };
        }
        self.writeIndexHeader() catch |err| {
            self.invalidated = true;
            return err;
        };
        self.rebuildBitmap() catch |err| {
            self.invalidated = true;
            return err;
        };
    }

    fn indexBytes(self: *Volume, offset: u64, output: []u8) anyerror!void {
        const index_size = @as(u64, self.checked.disk.index_blocks) * self.device.block_size;
        const end = std.math.add(u64, offset, output.len) catch return error.InvalidImage;
        if (end > index_size) return error.InvalidImage;

        var copied: usize = 0;
        while (copied < output.len) {
            const absolute = offset + copied;
            const block_index: u32 = 1 + @as(u32, @intCast(absolute / self.device.block_size));
            const within: usize = @intCast(absolute % self.device.block_size);
            const block = try io.readBlock(self.device, &self.scratch, block_index);
            const amount = @min(output.len - copied, block.len - within);
            @memcpy(output[copied .. copied + amount], block[within .. within + amount]);
            copied += amount;
        }
    }

    fn fileAt(self: *Volume, slot: u32) anyerror!wire.FileEntry {
        const offset = @as(u64, self.checked.index.file_offset) +
            @as(u64, slot) * wire.file_entry_bytes;
        var bytes = self.scratch.staging(self.device.block_size);
        try self.indexBytes(offset, bytes[0..wire.file_entry_bytes]);
        return wire.decodeFileEntry(bytes[0..wire.file_entry_bytes]);
    }

    fn decodeParent(self: *const Volume, entry: wire.FileEntry) Error!u16 {
        const flagged = self.checked.disk.feature_flags & (1 << 3) != 0;
        if (!flagged and entry.parent_or_flags & 1 != 0) return error.InvalidImage;
        return if (flagged) entry.parent_or_flags & 0xFFFE else entry.parent_or_flags;
    }

    fn rawNameAt(self: *Volume, slot: u32) anyerror![]u8 {
        const offset = @as(u64, self.checked.index.name_offset) +
            @as(u64, slot) * self.checked.name_size;
        const bytes = self.scratch.staging(self.device.block_size)[0..self.checked.name_size];
        try self.indexBytes(offset, bytes);
        return bytes;
    }

    fn nameAt(self: *Volume, slot: u32) anyerror![]u8 {
        const bytes = try self.rawNameAt(slot);
        var length: usize = 0;
        while (length < bytes.len and bytes[length] != 0) : (length += 1) {}
        if (length == 0) return error.InvalidImage;
        return bytes[0..length];
    }

    fn nameSlot(self: *Volume, wanted: []const u8) anyerror!?u32 {
        var slot: u32 = 0;
        while (slot < self.checked.index.name_capacity) : (slot += 1) {
            const name = try self.nameAt(slot);
            if (std.mem.eql(u8, name, wanted)) return slot;
        }
        return null;
    }

    fn fileInfo(self: *Volume, entry: wire.FileEntry) anyerror!FileInfo {
        const parent = try self.decodeParent(entry);
        const is_dir = entry.id & 1 == 0;
        return .{
            .id = .{ .value = entry.id },
            .parent = .{ .value = parent },
            .kind = if (is_dir) .directory else .regular,
            .details = if (is_dir) .{ .direct_children = entry.size_or_children } else .{ .regular_size = entry.size_or_children },
            .read_only = (self.checked.disk.feature_flags & (1 << 3) != 0) and
                (entry.parent_or_flags & 1 != 0),
        };
    }

    fn entryById(self: *Volume, id: FileId) anyerror!?wire.FileEntry {
        var slot: u32 = 0;
        while (slot < self.checked.index.file_first_available) : (slot += 1) {
            const entry = try self.fileAt(slot);
            if (entry.id == id.value) return entry;
        }
        return null;
    }

    /// Returns metadata for an ID. Root is implicit and has no stored size.
    pub fn stat(self: *Volume, id: FileId) anyerror!FileInfo {
        try self.ready();
        if (id.value == 0) return .{
            .id = .root,
            .parent = .root,
            .kind = .directory,
            .details = .{ .direct_children = 0 },
            .read_only = false,
        };
        const entry = (try self.entryById(id)) orelse return error.NotFound;
        return self.fileInfo(entry);
    }

    /// Looks up a child by its exact case-sensitive byte name.
    pub fn lookup(self: *Volume, parent: FileId, name: []const u8) anyerror!?FileInfo {
        try self.ready();
        if (name.len == 0 or name.len > self.checked.name_size) return error.InvalidInput;
        const parent_info = try self.stat(parent);
        if (parent_info.kind != .directory) return error.NotDirectory;

        var slot: u32 = 0;
        while (slot < self.checked.index.file_first_available) : (slot += 1) {
            const entry = try self.fileAt(slot);
            if (try self.decodeParent(entry) != parent.value) continue;
            const stored = try self.nameAt(entry.name_index);
            if (std.mem.eql(u8, stored, name)) return @as(?FileInfo, try self.fileInfo(entry));
        }
        return null;
    }

    /// Returns the next matching entry, copying its name into caller storage.
    /// `cursor` is a file-table slot; keep one cursor per directory walk.
    pub fn listNext(self: *Volume, parent: FileId, cursor: *u32, name_out: []u8) anyerror!?NamedEntry {
        try self.ready();
        const parent_info = try self.stat(parent);
        if (parent_info.kind != .directory) return error.NotDirectory;
        while (cursor.* < self.checked.index.file_first_available) : (cursor.* += 1) {
            const entry = try self.fileAt(cursor.*);
            if (try self.decodeParent(entry) != parent.value) continue;
            const stored = try self.nameAt(entry.name_index);
            if (stored.len > name_out.len) return error.BufferTooSmall;
            @memcpy(name_out[0..stored.len], stored);
            const result = NamedEntry{ .info = try self.fileInfo(entry), .name_length = stored.len };
            cursor.* += 1;
            return result;
        }
        return null;
    }

    fn extentPage(self: *Volume, slot: u16) anyerror!wire.ExtentPage {
        const offset = @as(u64, self.checked.index.extent_offset) + @as(u64, slot) * wire.extent_page_bytes;
        var bytes = self.scratch.staging(self.device.block_size);
        try self.indexBytes(offset, bytes[0..wire.extent_page_bytes]);
        return wire.decodeExtentPage(bytes[0..wire.extent_page_bytes]);
    }

    /// Streams bytes into `output`; returns zero at or beyond EOF.
    pub fn readAt(self: *Volume, id: FileId, offset: u64, output: []u8) anyerror!usize {
        try self.ready();
        const entry = (try self.entryById(id)) orelse return error.NotFound;
        if (entry.id & 1 == 0) return error.IsDirectory;
        if (offset >= entry.size_or_children or output.len == 0) return 0;
        const remaining = @min(output.len, @as(usize, @intCast(@as(u64, entry.size_or_children) - offset)));

        var logical: u64 = 0;
        var copied: usize = 0;
        var page_index = entry.first_extent;
        var expected_ordinal: u16 = 1;
        while (page_index != wire.no_link and copied < remaining) {
            const page = try self.extentPage(page_index);
            if (page.ordinal != expected_ordinal) return error.InvalidImage;
            for (page.entries) |extent| {
                if (extent.block_count == 0) break;
                const extent_bytes = @as(u64, extent.block_count) * self.device.block_size;
                if (offset >= logical + extent_bytes) {
                    logical += extent_bytes;
                    continue;
                }
                var within_extent = if (offset > logical) offset - logical else 0;
                while (within_extent < extent_bytes and copied < remaining) {
                    const block_delta: u32 = @intCast(within_extent / self.device.block_size);
                    const byte_in_block: usize = @intCast(within_extent % self.device.block_size);
                    const physical = extent.start_block + block_delta;
                    const data = try io.readBlock(self.device, &self.scratch, physical);
                    const amount = @min(remaining - copied, data.len - byte_in_block);
                    @memcpy(output[copied .. copied + amount], data[byte_in_block .. byte_in_block + amount]);
                    copied += amount;
                    within_extent += amount;
                }
                logical += extent_bytes;
                if (copied == remaining) break;
            }
            page_index = page.next;
            expected_ordinal +|= 1;
        }
        if (copied != remaining) return error.InvalidImage;
        return copied;
    }
};

/// Formats an empty default-layout image. Only blocks 0 and 1 are written;
/// free blocks retain their existing bytes and are not considered allocated.
pub fn format(device: BlockDevice, scratch_bytes: []u8) anyerror!void {
    if (device.write_block == null) return error.ReadOnly;
    if (device.block_size < 64 or device.block_count < 8) return error.InvalidInput;
    const bitmap_bits = (@as(u64, device.block_size) - 32) * 8;
    if (device.block_count > bitmap_bits or device.block_size > std.math.maxInt(usize) - wire.max_name_bytes)
        return error.InvalidInput;

    var scratch = try Scratch.init(scratch_bytes, device.block_size);
    @memset(scratch.block(device.block_size), 0);
    var block0 = scratch.block(device.block_size);
    try wire.encodeDiskHeader(block0, .{
        .magic = wire.disk_magic,
        .format = wire.format_id,
        .block_size = device.block_size,
        .disk_blocks = device.block_count,
        .index_blocks = 1,
        .feature_flags = 0,
    }, false);
    // Reserve blocks 0 and 1. Real data blocks start free, while tail bits
    // beyond the reported device geometry remain reserved.
    const bitmap = block0[32..];
    @memset(bitmap, 0);
    bitmap[0] = 0x03;
    const full_tail_byte: usize = device.block_count / 8;
    const tail_bits: u3 = @intCast(device.block_count % 8);
    if (tail_bits != 0) {
        bitmap[full_tail_byte] |= @as(u8, 0xFF) << tail_bits;
    }
    const first_full_tail = full_tail_byte + @as(usize, if (tail_bits == 0) 0 else 1);
    @memset(bitmap[first_full_tail..], 0xFF);
    try io.writeBlock(device, &scratch, 0);

    @memset(scratch.block(device.block_size), 0);
    try wire.encodeIndexHeader(scratch.block(device.block_size), .{
        .file_offset = 64,
        .file_first_available = 0,
        .file_capacity = 0,
        .name_offset = 64,
        .name_first_available = 0,
        .name_capacity = 0,
        .extent_offset = 64,
        .extent_first_available = 0,
        .extent_capacity = 0,
    }, false);
    try io.writeBlock(device, &scratch, 1);
}

test "format creates an image that opens after complete validation" {
    const TestDisk = struct {
        bytes: [1024]u8 = @splat(0xA5),
        writes: u32 = 0,
        fail_at: ?u32 = null,
        fail_read_after_writes: ?u32 = null,
    };
    const Adapter = struct {
        fn read(context: ?*anyopaque, block: u32, output: []u8) anyerror!void {
            const disk: *TestDisk = @ptrCast(@alignCast(context.?));
            if (disk.fail_read_after_writes) |threshold| {
                if (disk.writes > threshold) return error.DeviceFailure;
            }
            const start: usize = @as(usize, block) * 64;
            @memcpy(output, disk.bytes[start .. start + output.len]);
        }
        fn write(context: ?*anyopaque, block: u32, input: []const u8) anyerror!void {
            const disk: *TestDisk = @ptrCast(@alignCast(context.?));
            if (disk.fail_at) |fail_at| if (disk.writes >= fail_at) return error.DeviceFailure;
            const start: usize = @as(usize, block) * 64;
            @memcpy(disk.bytes[start .. start + input.len], input);
            disk.writes += 1;
        }
    };

    var disk = TestDisk{};
    const device = BlockDevice{
        .context = @ptrCast(&disk),
        .block_size = 64,
        .block_count = 16,
        .read_block = Adapter.read,
        .write_block = Adapter.write,
    };
    var scratch: [128]u8 = undefined;
    try format(device, &scratch);
    var volume = try Volume.open(device, &scratch);
    try std.testing.expectEqual(@as(u16, 1), volume.info().index_blocks);
    try std.testing.expectEqual(@as(u8, 32), volume.info().name_bytes);
    try std.testing.expectEqual(FileKind.directory, (try volume.stat(.root)).kind);

    const folder = try volume.create(.root, "docs", .directory);
    const file = try volume.create(folder.id, "hello.txt", .regular);
    try std.testing.expectEqual(FileKind.regular, file.kind);
    const found = (try volume.lookup(folder.id, "hello.txt")).?;
    try std.testing.expectEqual(file.id.value, found.id.value);
    var root_cursor: u32 = 0;
    var name_buffer: [64]u8 = undefined;
    const listed = (try volume.listNext(.root, &root_cursor, &name_buffer)).?;
    try std.testing.expectEqualStrings("docs", name_buffer[0..listed.name_length]);
    const payload: [70]u8 = @splat(0x6D);
    try std.testing.expectEqual(@as(usize, 70), try volume.writeAt(file.id, 0, &payload));
    const other = try volume.create(.root, "other", .regular);
    const other_payload: [64]u8 = @splat(0x2B);
    try std.testing.expectEqual(@as(usize, 64), try volume.writeAt(other.id, 0, &other_payload));
    try volume.resize(file.id, 128);
    const tail = [_]u8{0x7F};
    try std.testing.expectEqual(@as(usize, 1), try volume.writeAt(file.id, 128, &tail));
    var readback: [129]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 129), try volume.readAt(file.id, 0, &readback));
    try std.testing.expectEqualSlices(u8, &payload, readback[0..70]);
    for (readback[70..128]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(@as(u8, 0x7F), readback[128]);
    try volume.resize(file.id, 50);
    const writes_before_no_space = disk.writes;
    try std.testing.expectError(error.NoSpace, volume.resize(file.id, 100000));
    try std.testing.expectEqual(writes_before_no_space, disk.writes);
    var reopened = try Volume.open(device, &scratch);
    try std.testing.expectEqual(@as(u16, 8), reopened.info().index_blocks);
    try std.testing.expectEqual(@as(u32, 1), (try reopened.stat(folder.id)).details.direct_children);
    var relocated_bytes: [50]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 50), try reopened.readAt(file.id, 0, &relocated_bytes));
    try std.testing.expectEqualSlices(u8, payload[0..50], &relocated_bytes);
    try reopened.delete(file.id);
    try reopened.delete(folder.id);
    try reopened.delete(other.id);
    var reused = try Volume.open(device, &scratch);
    const replacement = try reused.create(.root, "replacement", .regular);
    try std.testing.expect((try reused.lookup(.root, "replacement")) != null);
    try reused.delete(replacement.id);

    // Interleaved allocations force one file's stream across two extents.
    try format(device, &scratch);
    var fragmented = try Volume.open(device, &scratch);
    const split_file = try fragmented.create(.root, "split", .regular);
    const interleaver = try fragmented.create(.root, "interleaver", .regular);
    const first_block: [64]u8 = @splat(0x31);
    const second_block: [64]u8 = @splat(0x52);
    _ = try fragmented.writeAt(split_file.id, 0, &first_block);
    _ = try fragmented.writeAt(interleaver.id, 0, &second_block);
    _ = try fragmented.writeAt(split_file.id, 64, "z");
    var across_extents: [65]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 65), try fragmented.readAt(split_file.id, 0, &across_extents));
    try std.testing.expectEqualSlices(u8, &first_block, across_extents[0..64]);
    try std.testing.expectEqual(@as(u8, 'z'), across_extents[64]);
    _ = try Volume.open(device, &scratch);

    // Corrupt references and decoded names are rejected even when the outer
    // header and bitmap still look plausible.
    try format(device, &scratch);
    disk.bytes[0] ^= 1;
    try std.testing.expectError(error.InvalidImage, Volume.open(device, &scratch));
    try format(device, &scratch);
    disk.bytes[64] = 0xFF; // file table offset escapes the index block
    try std.testing.expectError(error.InvalidImage, Volume.open(device, &scratch));
    try format(device, &scratch);
    var checked_volume = try Volume.open(device, &scratch);
    const bad_file = try checked_volume.create(.root, "bad", .regular);
    const good_image = disk.bytes;
    const bad_slot = (try checked_volume.findFileSlot(bad_file.id)).?;
    const bad_entry = try checked_volume.fileAt(bad_slot);
    const parent_byte = 64 + checked_volume.checked.index.file_offset + bad_slot * wire.file_entry_bytes + 2;
    disk.bytes[parent_byte] = 2;
    try std.testing.expectError(error.InvalidImage, Volume.open(device, &scratch));
    disk.bytes = good_image;
    const name_byte = 64 + checked_volume.checked.index.name_offset + @as(u32, bad_entry.name_index) * checked_volume.checked.name_size;
    disk.bytes[name_byte] = 1;
    try std.testing.expectError(error.InvalidImage, Volume.open(device, &scratch));
    disk.bytes = good_image;
    const one_byte = [_]u8{0x42};
    _ = try checked_volume.writeAt(bad_file.id, 0, &one_byte);
    const allocated_image = disk.bytes;
    const allocated_entry = (try checked_volume.entryById(bad_file.id)).?;
    const page_byte = 64 + checked_volume.checked.index.extent_offset + @as(u32, allocated_entry.first_extent) * 64;
    disk.bytes[page_byte] = 0;
    try std.testing.expectError(error.InvalidImage, Volume.open(device, &scratch));
    disk.bytes = allocated_image;

    // Feature bit 3 is decoded for reading but makes this implementation's
    // first-release mutating API read-only.
    try format(device, &scratch);
    disk.bytes[18] = 8;
    var readonly_volume = try Volume.open(device, &scratch);
    try std.testing.expect(readonly_volume.info().read_only);
    try std.testing.expectError(error.ReadOnly, readonly_volume.create(.root, "x", .regular));

    // Compact fixed-header layout (bit 2), with zero-capacity tables.
    try format(device, &scratch);
    disk.bytes[18] = 4;
    @memset(disk.bytes[64..96], 0);
    try wire.encodeIndexHeader(disk.bytes[64..96], .{
        .file_offset = 32,
        .file_first_available = 0,
        .file_capacity = 0,
        .name_offset = 64,
        .name_first_available = 0,
        .name_capacity = 0,
        .extent_offset = 64,
        .extent_first_available = 0,
        .extent_capacity = 0,
    }, true);
    const fixed_volume = try Volume.open(device, &scratch);
    try std.testing.expectEqual(@as(u8, 32), fixed_volume.info().name_bytes);

    // Reduced bitmap padding (bit 5) moves its start to byte 24.
    try format(device, &scratch);
    disk.bytes[18] = 0x20;
    @memset(disk.bytes[24..64], 0);
    disk.bytes[24] = 0x03;
    @memset(disk.bytes[26..64], 0xFF);
    _ = try Volume.open(device, &scratch);

    // Reject both the undefined name-size combination and bitmap mismatches.
    try format(device, &scratch);
    disk.bytes[18] = 3;
    try std.testing.expectError(error.UnsupportedFeature, Volume.open(device, &scratch));
    try format(device, &scratch);
    disk.bytes[18] = 1;
    try std.testing.expectEqual(@as(u8, 16), (try Volume.open(device, &scratch)).info().name_bytes);
    try format(device, &scratch);
    disk.bytes[18] = 2;
    try std.testing.expectEqual(@as(u8, 64), (try Volume.open(device, &scratch)).info().name_bytes);
    try format(device, &scratch);
    disk.bytes[32] |= 1 << 2;
    try std.testing.expectError(error.InvalidImage, Volume.open(device, &scratch));

    try format(device, &scratch);
    var failing = try Volume.open(device, &scratch);
    disk.fail_at = disk.writes;
    try std.testing.expectError(error.DeviceFailure, failing.create(.root, "failure", .regular));
    try std.testing.expectError(error.VolumeInvalidated, failing.stat(.root));

    disk.fail_at = null;
    try format(device, &scratch);
    var read_failing = try Volume.open(device, &scratch);
    disk.fail_read_after_writes = disk.writes;
    try std.testing.expectError(error.DeviceFailure, read_failing.create(.root, "read-failure", .regular));
    try std.testing.expectError(error.VolumeInvalidated, read_failing.stat(.root));
}

test "formatter accepts a non power-of-two block size" {
    const OddDisk = struct { bytes: [520]u8 = @splat(0) };
    const Adapter = struct {
        fn read(context: ?*anyopaque, block: u32, output: []u8) anyerror!void {
            const disk: *OddDisk = @ptrCast(@alignCast(context.?));
            const start: usize = @as(usize, block) * 65;
            @memcpy(output, disk.bytes[start .. start + output.len]);
        }
        fn write(context: ?*anyopaque, block: u32, input: []const u8) anyerror!void {
            const disk: *OddDisk = @ptrCast(@alignCast(context.?));
            const start: usize = @as(usize, block) * 65;
            @memcpy(disk.bytes[start .. start + input.len], input);
        }
    };
    var disk = OddDisk{};
    const device = BlockDevice{
        .context = @ptrCast(&disk),
        .block_size = 65,
        .block_count = 8,
        .read_block = Adapter.read,
        .write_block = Adapter.write,
    };
    var scratch: [129]u8 = undefined;
    try format(device, &scratch);
    _ = try Volume.open(device, &scratch);
}
