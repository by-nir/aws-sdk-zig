const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

const ENDIAN = @import("builtin").cpu.arch.endian();

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

    pub fn append(self: *SerialWriter, allocator: Allocator, comptime T: type, value: T) !void {
        const initial_len = self.length();
        errdefer self.buffer.shrinkRetainingCapacity(initial_len);

        switch (@typeInfo(T)) {
            .Bool, .Int, .Float, .Enum => try self.writeValue(allocator, T, value),
            .Union => |meta| {
                inline for (meta.fields) |field| {
                    if (comptime isSerializableChild(field.type)) continue;
                    compileErrorFmt("Union field `{}.{s}` is not encodeable", .{ T, field.name });
                }

                try self.writeValue(allocator, T, value);
            },
            inline .Optional, .Array, .Vector => |meta| {
                if (comptime isSerializableChild(meta.child)) {
                    try self.writeValue(allocator, T, value);
                } else {
                    compileErrorFmt("Type `{}` child is not encodeable", .{T});
                }
            },
            .Pointer => |meta| {
                switch (@typeInfo(meta.child)) {
                    .Pointer => @compileError("Encoding pointer to pointer is unsupported"),
                    .Struct => @compileError("Encoding struct pointer is unsupported"),
                    else => {},
                }

                switch (meta.size) {
                    .One => {
                        try self.writePadding(allocator, meta.alignment);
                        try self.buffer.appendSlice(allocator, mem.asBytes(value));
                    },
                    .Many => {
                        const opaque_sent = meta.sentinel orelse {
                            @compileError("Encoding many-item pointer expects sentinel-terminated");
                        };
                        const sentinel = comptime @as(*const meta.child, @ptrCast(@alignCast(opaque_sent))).*;
                        const slice = mem.sliceTo(value, sentinel);
                        try self.append(allocator, @TypeOf(slice), slice);
                    },
                    .Slice => {
                        // Length bytes count
                        const len_size: u8 = (std.math.log2_int_ceil(usize, value.len + 1) + 7) / 8;
                        try self.buffer.ensureUnusedCapacity(allocator, len_size + 1);
                        self.buffer.appendAssumeCapacity(len_size);

                        // Length
                        const len_bytes = mem.asBytes(&value.len);
                        if (ENDIAN == .little) {
                            self.buffer.appendSliceAssumeCapacity(len_bytes[0..len_size]);
                        } else {
                            const slice = len_bytes[len_bytes.len - len_size ..][0..len_size];
                            self.buffer.appendSliceAssumeCapacity(slice);
                        }

                        // Items
                        try self.writePadding(allocator, meta.alignment);
                        try self.buffer.appendSlice(allocator, value);

                        // Sentinel
                        if (meta.sentinel) |opq| {
                            const sentinel = comptime @as(*const meta.child, @ptrCast(@alignCast(opq))).*;
                            try self.append(allocator, meta.child, sentinel);
                        }
                    },
                    .C => @compileError("Encoding ‘c’ pointer is unsupported"),
                }
            },
            .Struct => |meta| {
                if (comptime !serializable(T)) {
                    compileErrorFmt("Struct `{}` contains non-encodeable field", .{T});
                }

                inline for (meta.fields) |field| {
                    try self.append(allocator, field.type, @field(value, field.name));
                }
            },
            else => compileErrorFmt("Unsupported encoding type `{}`", .{T}),
        }
    }

    fn writeValue(self: *SerialWriter, allocator: Allocator, comptime T: type, value: T) !void {
        try self.writePadding(allocator, @alignOf(T));
        try self.buffer.appendSlice(allocator, mem.asBytes(&value));
    }

    fn writePadding(self: *SerialWriter, allocator: Allocator, comptime alignment: comptime_int) !void {
        const initial = self.length();
        const target = mem.alignForward(usize, initial, alignment);
        if (target > initial) try self.buffer.resize(allocator, target);
    }

    fn length(self: SerialWriter) usize {
        return self.buffer.items.len;
    }
};

test "SerialWriter" {
    const slice = blk: {
        var writer = SerialWriter{};
        errdefer writer.deinit(test_alloc);

        try writer.append(test_alloc, bool, true);
        try writer.append(test_alloc, bool, false);

        try writer.append(test_alloc, u8, 108);
        try writer.append(test_alloc, u16, 801);
        try writer.append(test_alloc, i32, -108);
        try writer.append(test_alloc, f32, 1.08);

        try writer.append(test_alloc, TestEnum, .bar);
        try writer.append(test_alloc, TestUnion, .bar);
        try writer.append(test_alloc, TestUnion, .{ .baz = 108 });

        try writer.append(test_alloc, ?u8, null);
        try writer.append(test_alloc, ?u8, 108);

        try writer.append(test_alloc, [2]u8, .{ 101, 102 });
        try writer.append(test_alloc, @Vector(2, u8), .{ 103, 104 });

        try writer.append(test_alloc, *const u8, &108);
        try writer.append(test_alloc, [*:0]const u8, &.{ 108, 109 });
        try writer.append(test_alloc, [:0]const u8, &.{ 108, 109 });
        try writer.append(test_alloc, []const u8, &.{ 108, 109 });

        const align_slice: [2]u8 align(2) = .{ 108, 109 };
        try writer.append(test_alloc, []align(2) const u8, &align_slice);

        try writer.append(test_alloc, TestStructAuto, .{ .int = 108, .string = "foo" });
        try writer.append(test_alloc, TestStructPack, .{ .c0 = 101, .c1 = 102, .c2 = 103 });

        break :blk try writer.consumeSlice(test_alloc);
    };

    defer test_alloc.free(slice);
    try testing.expectEqualSlices(u8, TEST_SLICE, slice);
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
                            var value: usize = 0;
                            const size = self.nextValue(u8);
                            const source = self.takeNextRange(self.cursor, size);
                            if (ENDIAN == .little) {
                                @memcpy(mem.asBytes(&value)[0..size], source);
                            } else {
                                const dest = mem.asBytes(&value);
                                @memcpy(dest[dest.len - size ..][0..size], source);
                            }
                            break :blk value;
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
        if (alignment) |a| {
            if (a != @alignOf(T)) return []align(a) const u8;
        }

        return []const u8;
    }

    fn takeSliceType(self: *SerialReader, comptime T: type, comptime alignment: ?u29) TypeSlice(T, alignment) {
        switch (@typeInfo(T)) {
            .Bool, .Int, .Float, .Enum, .Union, .Optional, .Array, .Vector => {
                const slice = self.takeNextRange(self.cursor, @sizeOf(T));
                return @alignCast(slice);
            },
            else => unreachable,
        }
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
        .Pointer, .Struct => false,
        else => true,
    };
}

inline fn compileErrorFmt(comptime format: []const u8, args: anytype) void {
    @compileError(std.fmt.comptimePrint(format, args));
}

const UNDF = 0xAA;
const TEST_SLICE = TEST_BOOLS ++ TEST_NUMS ++ TEST_TAGS ++ TEST_OPTION ++
    TEST_LISTS ++ TEST_POINTERS ++ TEST_STRUCTS;

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

const TestStructAuto = struct { int: u8, string: []const u8 };
const TestStructPack = packed struct { c0: u8, c1: u8, c2: u8 };
const TEST_STRUCTS: []const u8 = &[_]u8{
    108, 1, 3, 'f', 'o', 'o', // auto
    101, 102, 103, // pack
};
