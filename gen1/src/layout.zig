const std = @import("std");

pub const Error = error{ Overflow, OutOfBounds, InvalidAlignment };

pub fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.Overflow;
}

pub fn mul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.Overflow;
}

pub fn alignForward(value: u64, alignment: u64) Error!u64 {
    if (alignment == 0) return error.InvalidAlignment;
    const remainder = value % alignment;
    return if (remainder == 0) value else add(value, alignment - remainder);
}

pub fn checkedSlice(buffer: []u8, offset: u64, length: u64) Error![]u8 {
    const end = try add(offset, length);
    if (end > buffer.len) return error.OutOfBounds;
    return buffer[@intCast(offset)..@intCast(end)];
}

test "checked arithmetic rejects overflow and bounds errors" {
    try std.testing.expectError(error.Overflow, add(std.math.maxInt(u64), 1));
    var bytes = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.OutOfBounds, checkedSlice(&bytes, 3, 2));
    try std.testing.expectEqual(@as(u64, 128), try alignForward(65, 64));
}
