//! C ABI adapter for the allocation-free TBDFv1 library.
//!
//! The C caller owns both the opaque volume storage and the scratch buffer.
//! Storage must remain at least `tbdf_volume_storage_size()` bytes and suitably
//! aligned until close. Scratch and callback context must also remain alive.

const std = @import("std");
const tbdf = @import("tbdf.zig");

pub const CBlockDevice = extern struct {
    context: ?*anyopaque,
    block_size: u32,
    block_count: u32,
    read_block: ?*const fn (?*anyopaque, u32, [*]u8, usize) callconv(.c) c_int,
    write_block: ?*const fn (?*anyopaque, u32, [*]const u8, usize) callconv(.c) c_int,
};

pub const CFileInfo = extern struct {
    id: u16,
    parent: u16,
    kind: u8,
    read_only: u8,
    reserved: u16 = 0,
    regular_size: u32,
    direct_children: u32,
};

const CVolume = struct {
    device: CBlockDevice,
    volume: ?tbdf.Volume = null,
    active: bool = false,
};

const Status = enum(c_int) {
    ok = 0,
    end = 1,
    invalid_argument = 2,
    invalid_image = 3,
    unsupported_feature = 4,
    not_found = 5,
    already_exists = 6,
    not_directory = 7,
    is_directory = 8,
    read_only = 9,
    no_space = 10,
    id_exhausted = 11,
    buffer_too_small = 12,
    volume_invalidated = 13,
    io_error = 14,
    internal_error = 15,
};

fn statusFor(err: anyerror) c_int {
    return @backingInt(switch (err) {
        error.InvalidInput, error.ScratchTooSmall => Status.invalid_argument,
        error.InvalidImage, error.Corrupt => Status.invalid_image,
        error.UnsupportedFeature => Status.unsupported_feature,
        error.NotFound => Status.not_found,
        error.AlreadyExists => Status.already_exists,
        error.NotDirectory => Status.not_directory,
        error.IsDirectory => Status.is_directory,
        error.ReadOnly => Status.read_only,
        error.NoSpace => Status.no_space,
        error.IdExhausted => Status.id_exhausted,
        error.BufferTooSmall => Status.buffer_too_small,
        error.VolumeInvalidated => Status.volume_invalidated,
        else => Status.io_error,
    });
}

fn holder(storage: ?*anyopaque, storage_len: usize) ?*CVolume {
    const raw = storage orelse return null;
    if (storage_len < @sizeOf(CVolume)) return null;
    if (@intFromPtr(raw) % @alignOf(CVolume) != 0) return null;
    return @ptrCast(@alignCast(raw));
}

fn readAdapter(context: ?*anyopaque, block: u32, output: []u8) anyerror!void {
    const state: *CVolume = @ptrCast(@alignCast(context orelse return error.InvalidInput));
    const callback = state.device.read_block orelse return error.InvalidInput;
    if (callback(state.device.context, block, output.ptr, output.len) != 0) return error.DeviceFailure;
}

fn writeAdapter(context: ?*anyopaque, block: u32, input: []const u8) anyerror!void {
    const state: *CVolume = @ptrCast(@alignCast(context orelse return error.InvalidInput));
    const callback = state.device.write_block orelse return error.ReadOnly;
    if (callback(state.device.context, block, input.ptr, input.len) != 0) return error.DeviceFailure;
}

fn makeDevice(state: *CVolume) tbdf.BlockDevice {
    return .{
        .context = @ptrCast(state),
        .block_size = state.device.block_size,
        .block_count = state.device.block_count,
        .read_block = readAdapter,
        .write_block = if (state.device.write_block == null) null else writeAdapter,
    };
}

fn activeVolume(raw: ?*anyopaque) ?*tbdf.Volume {
    const state: *CVolume = @ptrCast(@alignCast(raw orelse return null));
    if (!state.active) return null;
    return if (state.volume) |*volume| volume else null;
}

fn copyInfo(source: tbdf.FileInfo, destination: *CFileInfo) void {
    destination.* = .{
        .id = source.id.value,
        .parent = source.parent.value,
        .kind = if (source.kind == .regular) 1 else 2,
        .read_only = @intFromBool(source.read_only),
        .regular_size = switch (source.details) {
            .regular_size => |size| size,
            .direct_children => 0,
        },
        .direct_children = switch (source.details) {
            .regular_size => 0,
            .direct_children => |count| count,
        },
    };
}

fn id(value: u16) tbdf.FileId {
    return .{ .value = value };
}

fn bytes(pointer: ?[*]const u8, length: usize) ?[]const u8 {
    if (length == 0) return &.{};
    const ptr = pointer orelse return null;
    return ptr[0..length];
}

fn mutableBytes(pointer: ?[*]u8, length: usize) ?[]u8 {
    if (length == 0) return &.{};
    const ptr = pointer orelse return null;
    return ptr[0..length];
}

pub export fn tbdf_volume_storage_size() usize {
    return @sizeOf(CVolume);
}

pub export fn tbdf_volume_storage_align() usize {
    return @alignOf(CVolume);
}

pub export fn tbdf_format(device: ?*const CBlockDevice, scratch: ?[*]u8, scratch_len: usize) c_int {
    const description = device orelse return @backingInt(Status.invalid_argument);
    if (description.read_block == null) return @backingInt(Status.invalid_argument);
    const buffer = mutableBytes(scratch, scratch_len) orelse return @backingInt(Status.invalid_argument);
    var state = CVolume{ .device = description.* };
    tbdf.format(makeDevice(&state), buffer) catch |err| return statusFor(err);
    return @backingInt(Status.ok);
}

pub export fn tbdf_volume_open(
    storage: ?*anyopaque,
    storage_len: usize,
    device: ?*const CBlockDevice,
    scratch: ?[*]u8,
    scratch_len: usize,
) c_int {
    const state = holder(storage, storage_len) orelse return @backingInt(Status.invalid_argument);
    const description = device orelse return @backingInt(Status.invalid_argument);
    if (description.read_block == null) return @backingInt(Status.invalid_argument);
    const buffer = mutableBytes(scratch, scratch_len) orelse return @backingInt(Status.invalid_argument);
    state.* = .{ .device = description.* };
    state.volume = tbdf.Volume.open(makeDevice(state), buffer) catch |err| return statusFor(err);
    state.active = true;
    return @backingInt(Status.ok);
}

pub export fn tbdf_volume_close(storage: ?*anyopaque, storage_len: usize) c_int {
    const state = holder(storage, storage_len) orelse return @backingInt(Status.invalid_argument);
    state.active = false;
    state.volume = null;
    return @backingInt(Status.ok);
}

pub export fn tbdf_stat(volume: ?*anyopaque, file_id: u16, output: ?*CFileInfo) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    const result = output orelse return @backingInt(Status.invalid_argument);
    const info = handle.stat(id(file_id)) catch |err| return statusFor(err);
    copyInfo(info, result);
    return @backingInt(Status.ok);
}

pub export fn tbdf_lookup(
    volume: ?*anyopaque,
    parent_id: u16,
    name: ?[*]const u8,
    name_len: usize,
    output: ?*CFileInfo,
) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    const result = output orelse return @backingInt(Status.invalid_argument);
    const name_slice = bytes(name, name_len) orelse return @backingInt(Status.invalid_argument);
    const found = handle.lookup(id(parent_id), name_slice) catch |err| return statusFor(err);
    const info = found orelse return @backingInt(Status.not_found);
    copyInfo(info, result);
    return @backingInt(Status.ok);
}

pub export fn tbdf_list_next(
    volume: ?*anyopaque,
    parent_id: u16,
    cursor: ?*u32,
    name_out: ?[*]u8,
    name_capacity: usize,
    name_length: ?*usize,
    output: ?*CFileInfo,
) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    const position = cursor orelse return @backingInt(Status.invalid_argument);
    const length = name_length orelse return @backingInt(Status.invalid_argument);
    const result = output orelse return @backingInt(Status.invalid_argument);
    const buffer = mutableBytes(name_out, name_capacity) orelse return @backingInt(Status.invalid_argument);
    const found = handle.listNext(id(parent_id), position, buffer) catch |err| return statusFor(err);
    const item = found orelse return @backingInt(Status.end);
    copyInfo(item.info, result);
    length.* = item.name_length;
    return @backingInt(Status.ok);
}

pub export fn tbdf_read_at(
    volume: ?*anyopaque,
    file_id: u16,
    offset: u64,
    output: ?[*]u8,
    output_len: usize,
    bytes_read: ?*usize,
) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    const destination = mutableBytes(output, output_len) orelse return @backingInt(Status.invalid_argument);
    const count = bytes_read orelse return @backingInt(Status.invalid_argument);
    count.* = handle.readAt(id(file_id), offset, destination) catch |err| return statusFor(err);
    return @backingInt(Status.ok);
}

pub export fn tbdf_write_at(
    volume: ?*anyopaque,
    file_id: u16,
    offset: u64,
    input: ?[*]const u8,
    input_len: usize,
    bytes_written: ?*usize,
) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    const source = bytes(input, input_len) orelse return @backingInt(Status.invalid_argument);
    const count = bytes_written orelse return @backingInt(Status.invalid_argument);
    count.* = handle.writeAt(id(file_id), offset, source) catch |err| return statusFor(err);
    return @backingInt(Status.ok);
}

pub export fn tbdf_resize(volume: ?*anyopaque, file_id: u16, new_size: u64) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    handle.resize(id(file_id), new_size) catch |err| return statusFor(err);
    return @backingInt(Status.ok);
}

pub export fn tbdf_create(
    volume: ?*anyopaque,
    parent_id: u16,
    name: ?[*]const u8,
    name_len: usize,
    kind: u8,
    output: ?*CFileInfo,
) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    const result = output orelse return @backingInt(Status.invalid_argument);
    const name_slice = bytes(name, name_len) orelse return @backingInt(Status.invalid_argument);
    const file_kind: tbdf.FileKind = switch (kind) {
        1 => .regular,
        2 => .directory,
        else => return @backingInt(Status.invalid_argument),
    };
    const info = handle.create(id(parent_id), name_slice, file_kind) catch |err| return statusFor(err);
    copyInfo(info, result);
    return @backingInt(Status.ok);
}

pub export fn tbdf_delete(volume: ?*anyopaque, file_id: u16) c_int {
    const handle = activeVolume(volume) orelse return @backingInt(Status.invalid_argument);
    handle.delete(id(file_id)) catch |err| return statusFor(err);
    return @backingInt(Status.ok);
}

test "C ABI adapter formats, opens, and streams a file" {
    const Disk = struct { bytes: [2048]u8 = @splat(0) };
    const Callbacks = struct {
        fn read(context: ?*anyopaque, block: u32, output: [*]u8, length: usize) callconv(.c) c_int {
            const disk: *Disk = @ptrCast(@alignCast(context.?));
            const start: usize = @as(usize, block) * 128;
            @memcpy(output[0..length], disk.bytes[start .. start + length]);
            return 0;
        }
        fn write(context: ?*anyopaque, block: u32, input: [*]const u8, length: usize) callconv(.c) c_int {
            const disk: *Disk = @ptrCast(@alignCast(context.?));
            const start: usize = @as(usize, block) * 128;
            @memcpy(disk.bytes[start .. start + length], input[0..length]);
            return 0;
        }
    };

    var disk = Disk{};
    const device = CBlockDevice{
        .context = @ptrCast(&disk),
        .block_size = 128,
        .block_count = 16,
        .read_block = Callbacks.read,
        .write_block = Callbacks.write,
    };
    var scratch: [192]u8 = undefined;
    try std.testing.expectEqual(@backingInt(Status.ok), tbdf_format(&device, &scratch, scratch.len));

    var storage_bytes: [@sizeOf(CVolume)]u8 align(@alignOf(CVolume)) = undefined;
    try std.testing.expectEqual(
        @backingInt(Status.ok),
        tbdf_volume_open(&storage_bytes, storage_bytes.len, &device, &scratch, scratch.len),
    );
    const handle: ?*anyopaque = @ptrCast(&storage_bytes);
    var created: CFileInfo = undefined;
    try std.testing.expectEqual(
        @backingInt(Status.ok),
        tbdf_create(handle, 0, "demo", 4, 1, &created),
    );
    try std.testing.expectEqual(@as(u8, 1), created.kind);
    const payload = "archive payload";
    var wrote: usize = 0;
    try std.testing.expectEqual(
        @backingInt(Status.ok),
        tbdf_write_at(handle, created.id, 0, payload, payload.len, &wrote),
    );
    try std.testing.expectEqual(payload.len, wrote);
    var result: [payload.len]u8 = undefined;
    var read: usize = 0;
    try std.testing.expectEqual(
        @backingInt(Status.ok),
        tbdf_read_at(handle, created.id, 0, &result, result.len, &read),
    );
    try std.testing.expectEqual(payload.len, read);
    try std.testing.expectEqualStrings(payload, &result);
    try std.testing.expectEqual(@backingInt(Status.ok), tbdf_volume_close(handle, storage_bytes.len));
}
