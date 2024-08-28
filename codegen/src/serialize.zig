const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const common = @import("utils/common.zig");

const UNDF = 0xAA;
const ENDIAN = @import("builtin").cpu.arch.endian();
pub const SerialHandle = common.RangeHandle(u32);

/// Do not use for encoding permanent storage or transmission as the serial format is platform-dependent.
pub const SerialWriter = struct {
    buffer: std.ArrayListUnmanaged(u8) = .{},

    pub fn deinit(self: *SerialWriter, allocator: Allocator) void {
        self.buffer.deinit(allocator);
    }

    /// Caller owns the returned memory.
    pub fn consumeSlice(self: *SerialWriter, allocator: Allocator) ![]u8 {
        return self.buffer.toOwnedSlice(allocator);
    }

    /// Caller owns the returned memory.
    pub fn consumeReader(self: *SerialWriter, allocator: Allocator) !SerialReader {
        return .{
            .buffer = try self.buffer.toOwnedSlice(allocator),
        };
    }

    /// Appending values may invalidate the slice.
    pub fn view(self: SerialWriter) []const u8 {
        return self.buffer.items;
    }

    pub fn length(self: SerialWriter) u32 {
        return @intCast(self.buffer.items.len);
    }

    pub fn append(self: *SerialWriter, allocator: Allocator, comptime T: type, value: T) !SerialHandle {
        const initial_cursor = self.length();
        errdefer self.buffer.shrinkRetainingCapacity(initial_cursor);

        switch (@typeInfo(T)) {
            .Bool, .Int, .Float, .Enum => {
                const offset = try self.writePadding(allocator, @alignOf(T));
                try self.buffer.appendSlice(allocator, mem.asBytes(&value));
                return self.handleFrom(offset);
            },
            .Union => |meta| {
                inline for (meta.fields) |field| {
                    if (comptime isSerializableChild(field.type)) continue;
                    compileErrorFmt("Union field `{}.{s}` is not encodeable", .{ T, field.name });
                }

                const offset = try self.writePadding(allocator, @alignOf(T));
                try self.buffer.appendSlice(allocator, mem.asBytes(&value));
                return self.handleFrom(offset);
            },
            inline .Optional, .Array, .Vector => |meta| {
                if (!comptime isSerializableChild(meta.child)) {
                    compileErrorFmt("Type `{}` child is not encodeable", .{T});
                }

                const offset = try self.writePadding(allocator, @alignOf(T));
                try self.buffer.appendSlice(allocator, mem.asBytes(&value));
                return self.handleFrom(offset);
            },
            .Pointer => |meta| {
                switch (@typeInfo(meta.child)) {
                    .Pointer => @compileError("Encoding pointer to pointer is unsupported"),
                    .Struct => @compileError("Encoding struct pointer is unsupported"),
                    else => {},
                }

                switch (meta.size) {
                    .One => {
                        const offset = try self.writePadding(allocator, meta.alignment);
                        try self.buffer.appendSlice(allocator, mem.asBytes(value));
                        return self.handleFrom(offset);
                    },
                    .Many => {
                        const slice = mem.sliceTo(value, pointerSentinel(meta));
                        return self.append(allocator, @TypeOf(slice), slice);
                    },
                    .Slice => {
                        // Length bytes count
                        const size_len = sizeByteLen(value.len);
                        try self.buffer.ensureUnusedCapacity(allocator, size_len + 1);
                        self.buffer.appendAssumeCapacity(size_len);

                        // Length
                        const len_bytes = mem.asBytes(&value.len);
                        if (ENDIAN == .little) {
                            self.buffer.appendSliceAssumeCapacity(len_bytes[0..size_len]);
                        } else {
                            const slice = len_bytes[len_bytes.len - size_len ..][0..size_len];
                            self.buffer.appendSliceAssumeCapacity(slice);
                        }

                        // Items
                        _ = try self.writePadding(allocator, meta.alignment);
                        try self.buffer.appendSlice(allocator, value);
                        const handle = self.handleFrom(initial_cursor);

                        // Sentinel
                        if (meta.sentinel) |opq| {
                            const sentinel = comptime @as(*const meta.child, @ptrCast(@alignCast(opq))).*;
                            _ = try self.append(allocator, meta.child, sentinel);
                        }

                        return handle;
                    },
                    .C => @compileError("Encoding ‘c’ pointer is unsupported"),
                }
            },
            .Struct => |meta| {
                if (meta.layout == .@"packed") {
                    const offset = try self.writePadding(allocator, @alignOf(T));
                    try self.buffer.appendSlice(allocator, mem.asBytes(&value));
                    return self.handleFrom(offset);
                } else if (comptime !serializable(T)) {
                    compileErrorFmt("Struct `{}` contains non-encodeable field", .{T});
                }

                var offset: usize = std.math.maxInt(usize);
                inline for (meta.fields) |field| {
                    const val = @field(value, field.name);
                    const handle = try self.append(allocator, field.type, val);
                    if (offset == std.math.maxInt(usize)) offset = handle.offset;
                }

                return if (offset != std.math.maxInt(usize)) self.handleFrom(offset) else SerialHandle.empty;
            },
            else => compileErrorFmt("Unsupported encoding type `{}`", .{T}),
        }
    }

    pub fn appendFmt(self: *SerialWriter, allocator: Allocator, comptime format: []const u8, args: anytype) !SerialHandle {
        const offset = self.length();
        errdefer self.buffer.shrinkRetainingCapacity(offset);

        _ = try self.buffer.addManyAsSlice(allocator, 3);
        try self.buffer.writer(allocator).print(format, args);

        const len = self.length() - offset - 3;
        if (len > std.math.maxInt(u16)) return error.StringOverflow;

        self.buffer.items[offset] = 2;
        const size_bytes = self.buffer.items[offset + 1 ..][0..2];
        mem.writeInt(u16, size_bytes, @truncate(len), ENDIAN);

        return .{
            .offset = @intCast(offset),
            .length = @intCast(len + 3),
        };
    }

    /// Enabling `auto_align` maintains a log2 alignment matching the source address.
    pub fn appendRaw(self: *SerialWriter, allocator: Allocator, bytes: []const u8, comptime auto_align: bool) !SerialHandle {
        const initial = self.length();
        errdefer self.buffer.shrinkRetainingCapacity(initial);

        const offset = if (!auto_align) initial else blk: {
            const addr = @intFromPtr(bytes.ptr);
            const is_64b = comptime @bitSizeOf(usize) > 32;
            if (is_64b and mem.isAligned(addr, 8))
                break :blk try self.writePadding(allocator, 8)
            else if (mem.isAligned(addr, 4))
                break :blk try self.writePadding(allocator, 4)
            else if (mem.isAligned(addr, 2))
                break :blk try self.writePadding(allocator, 2)
            else
                break :blk initial;
        };

        try self.buffer.appendSlice(allocator, bytes);
        return self.handleFrom(offset);
    }

    pub fn drop(self: *SerialWriter, count: usize) void {
        const len = self.length();
        std.debug.assert(count <= len);
        self.buffer.shrinkRetainingCapacity(len - count);
    }

    /// Only when runtime safety is enabled.
    pub fn invalidate(self: *SerialWriter, handle: SerialHandle) void {
        comptime if (!std.debug.runtime_safety) return;
        const slice = self.buffer.items[handle.offset..][0..handle.length];
        @memset(slice, UNDF);
    }

    /// Assumes a valid handle.
    pub fn canOverride(handle: SerialHandle, comptime T: type, value: T) bool {
        switch (@typeInfo(@TypeOf(value))) {
            .Struct => return false, // TODO
            .Pointer => |meta| {
                switch (@typeInfo(meta.child)) {
                    .Struct, .Pointer => return false,
                    else => {},
                }

                switch (meta.size) {
                    .C => @compileError("Encoding ‘c’ pointer is unsupported"),
                    .One => return handle.length == @sizeOf(meta.child),
                    else => {
                        const size_len = sizeByteLen(value.len);
                        var head = handle.offset + 1 + size_len;
                        head = mem.alignForward(u32, head, @alignOf(meta.child)) - handle.offset;
                        return handle.length == head + value.len * @sizeOf(meta.child);
                    },
                }
            },
            else => return handle.length == @sizeOf(T),
        }
    }

    pub fn override(self: *SerialWriter, handle: SerialHandle, comptime T: type, value: T) void {
        std.debug.assert(canOverride(handle, T, value));
        std.debug.assert(handle.offset + handle.length <= self.length());

        switch (@typeInfo(@TypeOf(value))) {
            .Struct => unreachable, // TODO
            .Pointer => |meta| switch (meta.size) {
                .C => @compileError("Encoding ‘c’ pointer is unsupported"),
                .One => self.buffer.replaceRangeAssumeCapacity(handle.offset, handle.length, mem.asBytes(value)),
                .Many => {
                    const slice = mem.sliceTo(value, pointerSentinel(meta));
                    self.override(handle, @TypeOf(slice), slice);
                },
                .Slice => {
                    var count_len: u8 = self.buffer.items[handle.offset];
                    const count = readBufferInt(self.buffer.items[handle.offset + 1 ..][0..count_len]);

                    if (value.len != count) {
                        const new_count_len = sizeByteLen(value.len);
                        if (count_len != new_count_len) {
                            count_len = new_count_len;
                            self.buffer.items[handle.offset] = new_count_len;
                        }

                        const count_bytes = mem.asBytes(&value.len);
                        self.buffer.replaceRangeAssumeCapacity(handle.offset + 1, count_len, switch (ENDIAN) {
                            .little => count_bytes[0..count_len],
                            .big => count_bytes[count_bytes.len - count_len ..][0..count_len],
                        });
                    }

                    const offset = mem.alignForward(usize, handle.offset + 1 + count_len, @alignOf(meta.child));
                    self.buffer.replaceRangeAssumeCapacity(offset, value.len * @sizeOf(meta.child), mem.sliceAsBytes(value));
                },
            },
            else => self.buffer.replaceRangeAssumeCapacity(handle.offset, handle.length, mem.asBytes(&value)),
        }
    }

    fn handleFrom(self: SerialWriter, offset: usize) SerialHandle {
        return .{
            .offset = @intCast(offset),
            .length = @intCast(self.length() - offset),
        };
    }

    fn sizeByteLen(count: usize) u8 {
        const bits = std.math.log2_int_ceil(usize, count + 1) + 7;
        return bits / 8;
    }

    fn pointerSentinel(comptime meta: std.builtin.Type.Pointer) meta.child {
        const opaque_sent = meta.sentinel orelse {
            @compileError("Encoding many-item pointer expects sentinel-terminated");
        };
        return comptime @as(*const meta.child, @ptrCast(@alignCast(opaque_sent))).*;
    }

    fn writePadding(self: *SerialWriter, allocator: Allocator, alignment: u29) !usize {
        const initial = self.length();
        const target = mem.alignForward(usize, initial, alignment);
        if (target > initial) try self.buffer.resize(allocator, target);
        return target;
    }
};

inline fn expectAppend(writer: *SerialWriter, offset: usize, length: usize, comptime T: type, value: T) !void {
    try testing.expectEqualDeep(SerialHandle{
        .offset = offset,
        .length = length,
    }, try writer.append(test_alloc, T, value));
}

test "SerialWriter" {
    const slice = blk: {
        var writer = SerialWriter{};
        errdefer writer.deinit(test_alloc);

        try expectAppend(&writer, 0, 1, bool, true);
        try expectAppend(&writer, 1, 1, bool, false);

        try expectAppend(&writer, 2, 1, u8, 108);
        try expectAppend(&writer, 4, 2, u16, 801);
        try expectAppend(&writer, 8, 4, i32, -108);
        try expectAppend(&writer, 12, 4, f32, 1.08);

        try expectAppend(&writer, 16, 1, TestEnum, .bar);
        try expectAppend(&writer, 17, 2, TestUnion, .bar);
        try expectAppend(&writer, 19, 2, TestUnion, .{ .baz = 108 });

        try expectAppend(&writer, 21, 2, ?u8, null);
        try expectAppend(&writer, 23, 2, ?u8, 108);

        try expectAppend(&writer, 25, 2, [2]u8, .{ 101, 102 });
        try expectAppend(&writer, 28, 2, @Vector(2, u8), .{ 103, 104 });

        try expectAppend(&writer, 30, 1, *const u8, &108);
        try expectAppend(&writer, 31, 4, [*:0]const u8, &.{ 108, 109 });
        try expectAppend(&writer, 36, 4, [:0]const u8, &.{ 108, 109 });
        try expectAppend(&writer, 41, 4, []const u8, &.{ 108, 109 });

        const align_slice: [2]u8 align(2) = .{ 108, 109 };
        try expectAppend(&writer, 45, 5, []align(2) const u8, &align_slice);

        try testing.expectEqualDeep(SerialHandle{
            .offset = 50,
            .length = 10,
        }, try writer.appendFmt(test_alloc, "foo {d}", .{108}));

        try expectAppend(&writer, 60, 6, TestStructAuto, .{ .int = 108, .string = "foo" });
        try expectAppend(&writer, 68, 4, TestStructPack, .{ .c0 = 101, .c1 = 102, .c2 = 103 });

        const str_align: [3]u8 align(4) = "foo".*;
        try testing.expectEqualDeep(SerialHandle{
            .offset = 72,
            .length = 3,
        }, try writer.appendRaw(test_alloc, &str_align, false));
        try testing.expectEqualDeep(SerialHandle{
            .offset = 80,
            .length = 3,
        }, try writer.appendRaw(test_alloc, &str_align, true));

        const val = try writer.append(test_alloc, []const u8, "foo");
        try testing.expectEqual(true, SerialWriter.canOverride(val, []const u8, "bar"));
        try testing.expectEqual(false, SerialWriter.canOverride(val, []const u8, "bazqux"));
        writer.override(val, []const u8, "bar");

        writer.invalidate(try writer.appendRaw(test_alloc, "foo", false));
        writer.drop(1);

        break :blk try writer.consumeSlice(test_alloc);
    };

    defer test_alloc.free(slice);
    try testing.expectEqualSlices(u8, TEST_SLICE ++ .{
        'f', 'o', 'o', //
        UNDF, UNDF, UNDF, UNDF, UNDF, 'f', 'o', 'o', //
        1, 3, 'b', 'a', 'r', //
        UNDF, UNDF, //
    }, slice);
}

/// Do not use for decoding permanent storage or transmission as the serial format is platform-dependent.
pub const SerialReader = struct {
    buffer: []const u8,
    cursor: usize = 0,

    pub fn next(self: *SerialReader, comptime T: type) T {
        switch (@typeInfo(T)) {
            .Bool, .Int, .Float, .Enum => return self.nextValue(T),
            .Union => |meta| {
                inline for (meta.fields) |field| {
                    if (comptime isSerializableChild(field.type)) continue;
                    compileErrorFmt("Union field `{}.{s}` is not decodeable", .{ T, field.name });
                }

                return self.nextValue(T);
            },
            inline .Optional, .Array, .Vector => |meta| {
                if (comptime isSerializableChild(meta.child)) {
                    return self.nextValue(T);
                } else {
                    compileErrorFmt("Type `{}` child is not decodeable", .{T});
                }
            },
            .Pointer => |meta| {
                if (!meta.is_const) @compileError("Decoding expects constant pointer");
                switch (@typeInfo(meta.child)) {
                    .Pointer => @compileError("Decoding pointer to pointer is unsupported"),
                    .Struct => @compileError("Decoding struct pointer is unsupported"),
                    else => {},
                }

                switch (meta.size) {
                    .One => {
                        self.skipPadding(meta.alignment);
                        const slice = self.takeSliceType(meta.child, meta.alignment);
                        return mem.bytesAsValue(meta.child, slice);
                    },
                    .Many => {
                        const opaque_sent = meta.sentinel orelse {
                            @compileError("Decoding many-item pointer expects sentinel-terminated");
                        };
                        const sentinel = comptime @as(*const meta.child, @ptrCast(@alignCast(opaque_sent))).*;
                        return @ptrCast(self.next([:sentinel]align(meta.alignment) const meta.child));
                    },
                    .Slice => {
                        const len = blk: {
                            const size = self.nextValue(u8);
                            const source = self.takeNextRange(self.cursor, size);
                            break :blk readBufferInt(source);
                        };

                        self.skipPadding(meta.alignment);
                        const slice = self.takeNextRange(self.cursor, len * @sizeOf(meta.child));
                        if (meta.sentinel != null) self.cursor += @sizeOf(meta.child);
                        return @ptrCast(@alignCast(slice));
                    },
                    .C => @compileError("Decoding ‘c’ pointer is unsupported"),
                }
            },
            .Struct => |meta| {
                if (meta.layout == .@"packed") {
                    return self.nextValue(T);
                }

                inline for (meta.fields) |field| {
                    if (comptime serializable(field.type)) continue;
                    compileErrorFmt("Struct field `{}.{s}` is not decodeable", .{ T, field.name });
                }

                var value: T = undefined;
                inline for (meta.fields) |field| {
                    @field(value, field.name) = self.next(field.type);
                }
                return value;
            },
            else => compileErrorFmt("Unsupported decoding type `{}`", .{T}),
        }
    }

    fn nextValue(self: *SerialReader, comptime T: type) T {
        self.skipPadding(@alignOf(T));
        const slice = self.takeSliceType(T, null);
        return mem.bytesToValue(T, slice);
    }

    fn skipPadding(self: *SerialReader, comptime alignment: comptime_int) void {
        self.cursor = mem.alignForward(usize, self.cursor, alignment);
    }

    fn TypeSlice(comptime T: type, comptime alignment: ?u29) type {
        if (alignment) |a| if (a != @alignOf(T)) {
            return []align(a) const u8;
        };

        return []const u8;
    }

    fn takeSliceType(self: *SerialReader, comptime T: type, comptime alignment: ?u29) TypeSlice(T, alignment) {
        const slice = self.takeNextRange(self.cursor, @sizeOf(T));
        return @alignCast(slice);
    }

    fn takeNextRange(self: *SerialReader, start: usize, n: usize) []const u8 {
        self.assertRemaining(n);
        self.cursor = start + n;
        return self.buffer[start..][0..n];
    }

    inline fn assertRemaining(self: SerialReader, n: usize) void {
        std.debug.assert(self.cursor + n <= self.buffer.len);
    }
};

fn readBufferInt(source: []const u8) usize {
    const len = source.len;
    var value: usize = 0;
    if (ENDIAN == .little) {
        @memcpy(mem.asBytes(&value)[0..len], source);
    } else {
        const dest = mem.asBytes(&value);
        @memcpy(dest[dest.len - len ..][0..len], source);
    }
    return value;
}

test "SerialReader" {
    var reader = SerialReader{ .buffer = TEST_SLICE };

    try testing.expectEqual(true, reader.next(bool));
    try testing.expectEqual(false, reader.next(bool));

    try testing.expectEqual(108, reader.next(u8));
    try testing.expectEqual(801, reader.next(u16));
    try testing.expectEqual(-108, reader.next(i32));
    try testing.expectEqual(1.08, reader.next(f32));

    try testing.expectEqual(TestEnum.bar, reader.next(TestEnum));
    try testing.expectEqual(TestUnion.bar, reader.next(TestUnion));
    try testing.expectEqual(TestUnion{ .baz = 108 }, reader.next(TestUnion));

    try testing.expectEqual(null, reader.next(?u8));
    try testing.expectEqual(108, reader.next(?u8));

    try testing.expectEqualDeep(.{ 101, 102 }, reader.next([2]u8));
    try testing.expectEqual(.{ 103, 104 }, reader.next(@Vector(2, u8)));

    try testing.expectEqualDeep(&@as(u8, 108), reader.next(*const u8));
    try testing.expectEqualSlices(u8, &[_:0]u8{ 108, 109 }, mem.sliceTo(reader.next([*:0]const u8), 0));
    try testing.expectEqualSlices(u8, &[_:0]u8{ 108, 109 }, reader.next([:0]const u8));
    try testing.expectEqualSlices(u8, &.{ 108, 109 }, reader.next([]const u8));

    const align_slice: [2]u8 align(2) = .{ 108, 109 };
    try testing.expectEqualSlices(u8, &align_slice, reader.next([]align(2) const u8));

    try testing.expectEqualStrings("foo 108", reader.next([]const u8));

    try testing.expectEqualDeep(
        TestStructAuto{ .int = 108, .string = "foo" },
        reader.next(TestStructAuto),
    );
    try testing.expectEqualDeep(
        TestStructPack{ .c0 = 101, .c1 = 102, .c2 = 103 },
        reader.next(TestStructPack),
    );
}

fn serializable(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Bool, .Int, .Float, .Enum => return true,
        .Union => |meta| {
            inline for (meta.fields) |field| {
                if (!comptime isSerializableChild(field.type)) return false;
            }
            return true;
        },
        .Optional, .Array, .Vector => |meta| return isSerializableChild(meta.child),
        .Pointer => |meta| {
            if (!meta.is_const) return false;
            if (!isSerializableChild(meta.child)) return false;
            return switch (meta.size) {
                .One, .Slice => comptime serializable(meta.child),
                .Many => meta.sentinel != null,
                .C => false,
            };
        },
        .Struct => |meta| {
            if (meta.layout == .@"packed") return true;
            inline for (meta.fields) |field| {
                if (!comptime serializable(field.type)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn isSerializableChild(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Pointer => false,
        .Struct => |meta| meta.layout == .@"packed",
        else => true,
    };
}

inline fn compileErrorFmt(comptime format: []const u8, args: anytype) void {
    @compileError(std.fmt.comptimePrint(format, args));
}

const TEST_SLICE = TEST_BOOLS ++ TEST_NUMS ++ TEST_TAGS ++ TEST_OPTION ++
    TEST_LISTS ++ TEST_POINTERS ++ TEST_FMT ++ TEST_STRUCTS;

const TEST_BOOLS: []const u8 = &.{ 1, 0 }; // true, false

const TEST_NUMS: []const u8 = if (ENDIAN == .little) &.{
    108, // u8
    UNDF, 0x21, 0x03, // u16 801
    UNDF, UNDF, 0x94, 0xFF, 0xFF, 0xFF, // i32 -108
    0x71, 0x3D, 0x8A, 0x3F, // f32 1.08
} else &.{
    108, // u8
    UNDF, 0x03, 0x21, // u16 801
    UNDF, UNDF, 0xFF, 0xFF, 0xFF, 0x94, // i32 -108
    0x3F, 0x8A, 0x3D, 0x71, // f32 1.08
};

const TestEnum = enum { foo, bar, baz };
const TestUnion = union(enum) { foo: u8, bar, baz: u8 };
const TEST_TAGS: []const u8 = &.{
    1, // TestEnum.bar
    1, 0, // TestUnion.bar
    2, 108, // TestUnion.baz 108
};

const TEST_OPTION: []const u8 = &.{
    0, 0, // null
    108, 1, // 108
};

const TEST_LISTS: []const u8 = &.{
    101, 102, // array
    UNDF, 103, 104, // vector
};

const TEST_POINTERS: []const u8 = &.{
    108, // one
    1, 2, 108, 109, 0, // many (sentinel)
    1, 2, 108, 109, 0, // slice sentinel
    1, 2, 108, 109, // slice
    1, 2, UNDF, 108, 109, // slice align(2)
};

const TEST_FMT = (if (ENDIAN == .little) &[_]u8{ 2, 7, 0 } else &[_]u8{ 2, 0, 7 }) ++ "foo 108";

const TestStructAuto = struct { int: u8, string: []const u8 };
const TestStructPack = packed struct { c0: u8, c1: u8, c2: u8 };
const TEST_STRUCTS: []const u8 = &[_]u8{
    108, 1, 3, 'f', 'o', 'o', // auto
    UNDF, UNDF, 101, 102, 103, 0, // pack
};
