const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub const SliceReader = struct {
    buffer: []const u8,
    cursor: usize = 0,

    pub fn countConsumed(self: SliceReader) usize {
        return self.cursor;
    }

    /// Ensures the required amount of bytes are available.
    pub fn reserve(self: *SliceReader, len: usize) !void {
        if (len > self.buffer.len - self.cursor) {
            @branchHint(.unlikely);
            return error.EndOfStream;
        }
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn drop(self: *SliceReader, len: usize) void {
        assert(len <= self.buffer.len - self.cursor);
        self.cursor += len;
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn peekByte(self: SliceReader, skip: usize) u8 {
        return self.buffer[skip + self.cursor];
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn peekSlice(self: SliceReader, skip: usize, len: usize) []const u8 {
        return self.buffer[skip + self.cursor ..][0..len];
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn takeByte(self: *SliceReader) u8 {
        defer self.cursor += 1;
        return self.buffer[self.cursor];
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn takeSlice(self: *SliceReader, len: usize) []const u8 {
        defer self.cursor += len;
        return self.buffer[self.cursor..][0..len];
    }
};

test SliceReader {
    var reader = SliceReader{ .buffer = "abcde" };

    try testing.expectEqual(0, reader.countConsumed());

    try reader.reserve(5);
    try testing.expectError(error.EndOfStream, reader.reserve(6));

    try testing.expectEqual('b', reader.peekByte(1));
    try testing.expectEqualStrings("bc", reader.peekSlice(1, 2));
    try testing.expectEqual(0, reader.countConsumed());

    reader.drop(2);
    try testing.expectEqual(2, reader.countConsumed());
    try reader.reserve(3);
    try testing.expectError(error.EndOfStream, reader.reserve(4));

    try testing.expectEqual('d', reader.peekByte(1));
    try testing.expectEqualStrings("de", reader.peekSlice(1, 2));
    try testing.expectEqual(2, reader.countConsumed());

    try testing.expectEqual('c', reader.takeByte());
    try testing.expectEqual(3, reader.countConsumed());
    try testing.expectEqualStrings("de", reader.takeSlice(2));
    try testing.expectEqual(5, reader.countConsumed());

    try testing.expectError(error.EndOfStream, reader.reserve(1));
}

pub fn GenericReader(comptime ReaderType: type, comptime buffer_size: usize) type {
    if (!isStdReader(ReaderType)) @compileError("Reader is not a valid std.io reader type");
    return struct {
        reader: ReaderType,
        cursor: usize = 0,
        prev_len: usize = 0,
        buffer_used: usize = 0,
        buffer: [buffer_size]u8 = undefined,

        const Self = @This();

        pub fn countConsumed(self: Self) usize {
            return self.prev_len + self.cursor;
        }

        /// Ensures the required amount of bytes are available, feed the buffer if needed.
        /// Returns `error.EndOfStream` when the source reader is depleted.
        /// Asserts the require amount is within buffer the buffer size.
        pub fn reserve(self: *Self, len: usize) !void {
            assert(len <= buffer_size);
            const unread = self.buffer_used - self.cursor;

            if (len <= unread) {
                // The buffer has enough bytes
                @branchHint(.likely);
                return;
            } else {
                // Remove consumed bytes from the buffer
                if (unread > self.cursor) {
                    std.mem.copyForwards(u8, self.buffer[0..unread], self.buffer[self.cursor..][0..unread]);
                } else if (unread != 0) {
                    @memcpy(self.buffer[0..unread], self.buffer[self.cursor..][0..unread]);
                }

                // Fill the buffer from the source reader
                self.buffer_used = unread + try self.reader.read(self.buffer[unread..buffer_size]);
                self.prev_len += self.cursor;
                self.cursor = 0;

                // The source may provide only a fraction of the requested length
                if (len > self.buffer_used) {
                    @branchHint(.unlikely);
                    return error.EndOfStream;
                }
            }
        }

        /// Must call `reserve` before this function. Asserts buffer bounds.
        pub fn drop(self: *Self, n: usize) void {
            assert(n <= self.buffer.len - self.cursor);
            self.cursor += n;
        }

        /// Must call `reserve` before this function. Asserts buffer bounds.
        pub fn peekByte(self: Self, skip: usize) u8 {
            return self.buffer[skip + self.cursor];
        }

        /// Must call `reserve` before this function. Asserts buffer bounds.
        pub fn peekSlice(self: Self, skip: usize, len: usize) []const u8 {
            return self.buffer[skip + self.cursor ..][0..len];
        }

        /// Must call `reserve` before this function. Asserts buffer bounds.
        pub fn takeByte(self: *Self) u8 {
            defer self.cursor += 1;
            return self.buffer[self.cursor];
        }

        /// Must call `reserve` before this function. Asserts buffer bounds.
        pub fn takeSlice(self: *Self, len: usize) []const u8 {
            defer self.cursor += len;
            return self.buffer[self.cursor..][0..len];
        }
    };
}

fn isStdReader(comptime T: type) bool {
    if (!std.meta.hasMethod(T, "read")) return false;

    const func = @typeInfo(@TypeOf(@field(T, "read"))).@"fn";
    if (func.params.len != 2) return false;
    if (func.params[0].type != T) return false;
    if (func.params[1].type != []u8) return false;

    return switch (@typeInfo(func.return_type.?)) {
        .error_union => |m| m.payload == usize,
        else => false,
    };
}

test GenericReader {
    var stream = std.io.fixedBufferStream("abcdef");
    var reader = GenericReader(@TypeOf(stream).Reader, 4){
        .reader = stream.reader(),
    };

    try testing.expectEqual(0, reader.countConsumed());

    // Fill buffer
    try reader.reserve(3);
    assert(reader.prev_len == 0);
    try testing.expectEqual('b', reader.peekByte(1));
    try testing.expectEqualStrings("bc", reader.peekSlice(1, 2));
    try testing.expectEqual(0, reader.countConsumed());

    reader.drop(1);
    try testing.expectEqual(1, reader.countConsumed());

    // Drop consumed and fill remaining
    try reader.reserve(4);
    assert(reader.prev_len == 1);
    try testing.expectEqualStrings("bcde", reader.peekSlice(0, 4));

    // Consume buffer without refilling
    try testing.expectEqual(1, reader.countConsumed());
    try testing.expectEqual('b', reader.takeByte());
    try testing.expectEqual(2, reader.countConsumed());
    try testing.expectEqualStrings("cd", reader.takeSlice(2));
    try testing.expectEqual(4, reader.countConsumed());

    // Fill the remaining source
    try reader.reserve(2);
    assert(reader.prev_len == 4);
    try testing.expectEqualStrings("ef", reader.peekSlice(0, 2));

    // Deplete the source
    reader.drop(2);
    try testing.expectEqual(6, reader.countConsumed());
    try testing.expectError(error.EndOfStream, reader.reserve(1));
}

pub const TestingReader = struct {
    cursor: usize = 0,
    fail: FailTrigger = .none,
    buffer: ?[]const u8 = null,

    pub const ResetOptions = struct {
        fail: FailTrigger = .none,
        buffer: ?[]const u8 = null,
    };

    pub const FailTrigger = union(enum) {
        none,
        cursor: usize,
        reserve: usize,
    };

    const fallback: [64]u8 = std.mem.zeroes([64]u8);

    pub fn reset(self: *TestingReader, options: ResetOptions) void {
        self.cursor = 0;
        self.fail = options.fail;
        self.buffer = options.buffer;
    }

    pub fn countConsumed(self: TestingReader) usize {
        return self.cursor;
    }

    /// Ensures the required amount of bytes are available.
    pub fn reserve(self: *TestingReader, len: usize) !void {
        if (self.buffer) |buf| {
            if (len > buf.len - self.cursor) return error.EndOfStream;
        }

        switch (self.fail) {
            .none => {},
            .cursor => |n| if (self.cursor >= n) return error.EndOfStream,
            .reserve => |n| if (self.cursor + len >= n) return error.EndOfStream,
        }
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn drop(self: *TestingReader, len: usize) void {
        if (self.buffer) |buf| assert(len <= buf.len - self.cursor);
        self.cursor += len;
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn peekByte(self: TestingReader, skip: usize) u8 {
        return if (self.buffer) |buf| buf[skip + self.cursor] else fallback[0];
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn peekSlice(self: TestingReader, skip: usize, len: usize) []const u8 {
        if (self.buffer) |buf| {
            return buf[skip + self.cursor ..][0..len];
        } else {
            assert(len <= fallback.len);
            return fallback[0..len];
        }
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn takeByte(self: *TestingReader) u8 {
        defer self.cursor += 1;
        return if (self.buffer) |buf| buf[self.cursor] else fallback[0];
    }

    /// Must call `reserve` before this function. Asserts buffer bounds.
    pub fn takeSlice(self: *TestingReader, len: usize) []const u8 {
        defer self.cursor += len;
        if (self.buffer) |buf| {
            return buf[self.cursor..][0..len];
        } else {
            assert(len <= fallback.len);
            return fallback[0..len];
        }
    }

    pub fn expectCursor(self: TestingReader, expected: usize) !void {
        try testing.expectEqual(expected, self.cursor);
    }

    pub fn expectReserveError(operation_output: anytype) !void {
        try testing.expectError(error.EndOfStream, operation_output);
    }
};

test TestingReader {
    var reader = TestingReader{};

    try reader.reserve(99);
    try testing.expectEqual(0, reader.countConsumed());

    reader.reset(.{ .buffer = "abcd" });
    try reader.reserve(4);
    try testing.expectError(error.EndOfStream, reader.reserve(5));

    reader.reset(.{ .fail = .{ .reserve = 5 } });
    try reader.reserve(4);
    try testing.expectError(error.EndOfStream, reader.reserve(5));

    reader.reset(.{
        .buffer = "abc",
        .fail = .{ .reserve = 5 },
    });
    try reader.reserve(3);
    try testing.expectError(error.EndOfStream, reader.reserve(4));

    reader.reset(.{
        .buffer = "abc",
        .fail = .{ .reserve = 2 },
    });
    try reader.reserve(1);
    try testing.expectError(error.EndOfStream, reader.reserve(2));

    reader.reset(.{ .fail = .{ .reserve = 5 } });
    reader.drop(2);
    try testing.expectEqual(2, reader.countConsumed());
    try reader.reserve(2);
    try testing.expectError(error.EndOfStream, reader.reserve(3));

    reader.reset(.{ .fail = .{ .cursor = 2 } });
    try reader.reserve(2);
    reader.drop(2);
    try testing.expectEqual(2, reader.countConsumed());
    try testing.expectError(error.EndOfStream, reader.reserve(1));

    reader.reset(.{ .buffer = "abcde" });
    try testing.expectEqual('b', reader.peekByte(1));
    try testing.expectEqualStrings("bc", reader.peekSlice(1, 2));
    try testing.expectEqual(0, reader.countConsumed());

    reader.drop(2);
    try testing.expectEqual(2, reader.countConsumed());
    try reader.reserve(3);
    try testing.expectError(error.EndOfStream, reader.reserve(4));

    try testing.expectEqual('d', reader.peekByte(1));
    try testing.expectEqualStrings("de", reader.peekSlice(1, 2));
    try testing.expectEqual(2, reader.countConsumed());

    try testing.expectEqual('c', reader.takeByte());
    try testing.expectEqual(3, reader.countConsumed());
    try testing.expectEqualStrings("de", reader.takeSlice(2));
    try testing.expectEqual(5, reader.countConsumed());

    try testing.expectError(error.EndOfStream, reader.reserve(1));
}
