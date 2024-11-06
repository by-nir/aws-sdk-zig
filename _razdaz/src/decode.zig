const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const test_alloc = testing.allocator;
const read = @import("read.zig");
const TestingReader = read.TestingReader;
const combine = @import("combine.zig");
const Operator = combine.Operator;
const BuildOp = combine.TestOperator;
const lib = @import("consume.zig");
const Consumer = lib.Consumer;
const EvalState = lib.EvalState;
pub const AllocatePref = lib.ConsumeBehavior.Allocate;

pub fn Value(comptime T: type) type {
    return union(enum) {
        /// A value or a reference that may be invalidated by further operations.
        view: T,
        /// An owned value that must be freed by the caller.
        owned: T,
    };
}

/// Decodes a complete slice.
pub const SliceDecoder = Decoder(read.SliceReader);

/// Decodes a stream backed by any std.io reader type.
pub fn ReaderDecoder(comptime ReaderType: type, comptime buffer_size: usize) type {
    return Decoder(read.GenericReader(ReaderType, buffer_size));
}

/// Decode a complete slice.
pub fn decodeSlice(allocator: Allocator, buffer: []const u8) SliceDecoder {
    const reader = read.SliceReader{ .buffer = buffer };
    return .{
        .reader = reader,
        .allocator = allocator,
    };
}

/// Decode a stream backed by any std.io reader type.
pub fn decodeReader(
    allocator: Allocator,
    reader: anytype,
    comptime buffer_size: usize,
) ReaderDecoder(@TypeOf(reader), buffer_size) {
    return .{
        .reader = reader,
        .allocator = allocator,
    };
}

/// Reader type is either `SliceDecoder` or any `GenericDecoder`.
fn Decoder(comptime Reader: type) type {
    return struct {
        reader: Reader,
        allocator: Allocator,

        const Self = @This();

        /// Drop bytes from the beginning of the stream.
        /// When the operation fails, returns `error.FailedOperation` **without rolling back the state**.
        pub fn skip(self: *Self, comptime operator: Operator) !void {
            comptime operator.validate(u8, null);
            const output = try Consumer(operator).evaluate(self.allocator, &self.reader, .stream_drop, 0);
            switch (output) {
                .ok => unreachable,
                .discard => {},
                .fail => {
                    @branchHint(.cold);
                    return error.FailedOperation;
                },
            }
        }

        /// Evaluate and consume bytes from the beginning of the stream.
        /// When the operation fails, returns `error.FailedOperation` **without rolling back the state**.
        pub fn take(
            self: *Self,
            comptime allocate: AllocatePref,
            comptime operator: Operator,
        ) !Value(operator.Output()) {
            comptime operator.validate(u8, null);
            const output = try Consumer(operator).evaluate(self.allocator, &self.reader, switch (allocate) {
                .avoid => .stream_take,
                .always => .stream_take_clone,
            }, 0);
            switch (output) {
                .discard => unreachable,
                .ok => |state| {
                    if (@TypeOf(state.owned) == bool and state.owned)
                        return .{ .owned = state.value }
                    else
                        return .{ .view = state.value };
                },
                .fail => {
                    @branchHint(.cold);
                    return error.FailedOperation;
                },
            }
        }

        /// Evaluate bytes from the beginning of the stream without consuming them.
        /// Returns a struct that allows consuming the value with or without advancing the decoder.
        /// When the operation fails, returns `error.FailedOperation` **without rolling back the state**.
        pub fn peek(self: *Self, comptime operator: Operator) !Peek(operator.Output()) {
            comptime operator.validate(u8, null);
            switch (try Consumer(operator).evaluate(self.allocator, &self.reader, .stream_view, 0)) {
                .discard => unreachable,
                .ok => |state| {
                    return .{
                        .state = state,
                        .decoder = self,
                    };
                },
                .fail => {
                    @branchHint(.cold);
                    return error.FailedOperation;
                },
            }
        }

        pub fn Peek(comptime T: type) type {
            const is_pointer = @typeInfo(T) == .pointer;
            return struct {
                decoder: *Self,
                state: EvalState(T),

                /// Get the value without advancing the reader.
                pub fn view(self: @This()) T {
                    return self.state.value;
                }

                /// Owns the returned value and advances the reader.
                pub fn consume(self: @This()) T {
                    self.commit();
                    return self.state.value;
                }

                /// Advances the reader without deallocating the value.
                pub fn commit(self: @This()) void {
                    self.decoder.reader.drop(self.state.used);
                }

                /// Advances the reader and deallocates the value.
                pub fn commitAndFree(self: @This()) void {
                    self.commit();
                    self.deinit();
                }

                /// Deallocates the value without advancing the reader.
                pub fn deinit(self: @This()) void {
                    if (!is_pointer or !self.state.owned) return;
                    const allocator = self.decoder.allocator;
                    switch (@typeInfo(T).pointer.size) {
                        .One => allocator.destroy(self.state.value),
                        .Slice => allocator.free(self.state.value),
                        else => @compileError("unsupported pointer type"),
                    }
                }
            };
        }
    };
}

test "skip" {
    var tester = TestingDecoder{};
    tester.reset(.{ .fail = .{ .cursor = 0 } });
    try tester.expectReaderError(tester.skip(BuildOp.matchSingle(.ok)));
    try tester.expectCursor(0);

    tester.reset(.{ .fail = .none });
    try tester.expectFailedOperation(tester.skip(BuildOp.matchSingle(.fail)));

    try tester.skip(BuildOp.matchSingle(.ok));
    try tester.expectCursor(1);

    try tester.skip(BuildOp.matchSequence(.done_include, .at(1)));
    try tester.expectCursor(3);
}

test "peek" {
    var tester = TestingDecoder{};
    tester.reset(.{ .buffer = "axxbcxxxx" });

    try tester.expectFailedOperation(tester.peek(BuildOp.matchSingle(.fail)));

    const char = try tester.peek(BuildOp.matchSingle(.ok));
    {
        errdefer char.deinit();
        try testing.expectEqual('a', char.view());
        try tester.expectCursor(0);
        char.commit();
        try tester.expectCursor(1);
        try testing.expectEqual('a', char.consume());
        try tester.expectCursor(2);
    }
    char.commitAndFree();
    try tester.expectCursor(3);

    const seq = try tester.peek(BuildOp.matchSequence(.done_include, .at(1)));
    {
        errdefer seq.deinit();
        try testing.expectEqualStrings("bc", seq.view());
        try tester.expectCursor(3);
        seq.commit();
        try tester.expectCursor(5);
        try testing.expectEqualStrings("bc", seq.consume());
        try tester.expectCursor(7);
    }
    seq.commitAndFree();
    try tester.expectCursor(9);

    try tester.expectReaderError(tester.peek(BuildOp.matchSingle(.ok)));
    try tester.expectCursor(9);
}

test "take" {
    var tester = TestingDecoder{};
    tester.reset(.{ .buffer = "abcdef" });

    try tester.expectFailedOperation(tester.take(.avoid, BuildOp.matchSingle(.fail)));

    try testing.expectEqualDeep(
        Value(u8){ .view = 'a' },
        try tester.take(.avoid, BuildOp.matchSingle(.ok)),
    );
    try tester.expectCursor(1);

    try testing.expectEqualDeep(
        Value(u8){ .view = 'b' },
        try tester.take(.always, BuildOp.matchSingle(.ok)),
    );
    try tester.expectCursor(2);

    {
        const val = try tester.take(.avoid, BuildOp.matchSequence(.done_include, .at(1)));
        defer test_alloc.free(val.owned);
        try testing.expectEqualDeep(Value([]const u8){ .owned = "cd" }, val);
    }
    try tester.expectCursor(4);

    {
        const val = try tester.take(.always, BuildOp.matchSequence(.done_include, .at(1)));
        defer test_alloc.free(val.owned);
        try testing.expectEqualDeep(Value([]const u8){ .owned = "ef" }, val);
    }
    try tester.expectCursor(6);

    try tester.expectReaderError(tester.take(.avoid, BuildOp.matchSingle(.ok)));
    try tester.expectCursor(6);
}

/// Utility for testing decoders.
pub const TestingDecoder = struct {
    decoder: Decoder(TestingReader) = .{
        .reader = .{},
        .allocator = test_alloc,
    },

    pub fn reset(self: *TestingDecoder, options: TestingReader.ResetOptions) void {
        self.decoder.reader.reset(options);
    }

    pub fn skip(self: *TestingDecoder, operator: BuildOp) !void {
        return self.decoder.skip(operator.build());
    }

    pub fn peek(
        self: *TestingDecoder,
        operator: BuildOp,
    ) !Decoder(TestingReader).Peek(operator.build().Output()) {
        return self.decoder.peek(operator.build());
    }

    pub fn take(
        self: *TestingDecoder,
        comptime allocate: AllocatePref,
        operator: BuildOp,
    ) !Value(operator.build().Output()) {
        return self.decoder.take(allocate, operator.build());
    }

    pub fn expectCursor(self: *TestingDecoder, expected: usize) !void {
        try self.decoder.reader.expectCursor(expected);
    }

    pub fn expectReaderError(_: *TestingDecoder, error_union: anytype) !void {
        try testing.expectError(error.EndOfStream, error_union);
    }

    pub fn expectFailedOperation(_: *TestingDecoder, error_union: anytype) !void {
        try testing.expectError(error.FailedOperation, error_union);
    }
};
