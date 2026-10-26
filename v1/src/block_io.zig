const std = @import("std");
const wire = @import("wire.zig");

pub const CallbackError = anyerror;

pub const BlockDevice = struct {
    context: ?*anyopaque = null,
    block_size: u32,
    block_count: u32,
    read_block: *const fn (?*anyopaque, u32, []u8) CallbackError!void,
    write_block: ?*const fn (?*anyopaque, u32, []const u8) CallbackError!void = null,
};

pub const Scratch = struct {
    bytes: []u8,

    pub fn init(bytes: []u8, block_size: u32) error{ScratchTooSmall}!Scratch {
        if (block_size > std.math.maxInt(usize) - wire.max_name_bytes) return error.ScratchTooSmall;
        const required: usize = @as(usize, block_size) + wire.max_name_bytes;
        if (bytes.len < required) return error.ScratchTooSmall;
        return .{ .bytes = bytes[0..required] };
    }

    pub fn block(self: *Scratch, size: u32) []u8 {
        return self.bytes[0..@intCast(size)];
    }

    pub fn staging(self: *Scratch, size: u32) []u8 {
        const start: usize = size;
        return self.bytes[start .. start + wire.max_name_bytes];
    }
};

pub fn readBlock(device: BlockDevice, scratch: *Scratch, index: u32) CallbackError![]u8 {
    const data = scratch.block(device.block_size);
    try device.read_block(device.context, index, data);
    return data;
}

pub fn writeBlock(device: BlockDevice, scratch: *Scratch, index: u32) CallbackError!void {
    const writer = device.write_block orelse return error.ReadOnly;
    try writer(device.context, index, scratch.block(device.block_size));
}
