const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const Allocator = std.mem.Allocator;
const combine = @import("combine.zig");
const BuildOp = combine.TestOperator;
const SizeHint = combine.Operator.SizeHint;
const TestingReader = @import("read.zig").TestingReader;

pub const ConsumeBehavior = enum {
    direct_clone,
    direct_view,
    stream_take_clone,
    stream_take,
    stream_view,
    stream_drop,

    pub const Allocate = enum {
        /// Avoids allocating the returned value when possible.
        avoid,
        /// Allocates a duplicate of a referenced value.
        always,
    };

    const Source = enum {
        /// The value or slice are accessible in their whole.
        direct,
        /// Consumable stream, without a guarantee of being able to access it at a given point as a whole.
        stream,
    };

    fn Skip(self: ConsumeBehavior) type {
        return if (self.canSkip()) usize else u0;
    }

    fn canSkip(self: ConsumeBehavior) bool {
        return switch (self) {
            .direct_clone, .direct_view, .stream_view => true,
            .stream_take_clone, .stream_take, .stream_drop => false,
        };
    }

    fn canTake(self: ConsumeBehavior) bool {
        return switch (self) {
            .stream_take_clone, .stream_take => true,
            else => false,
        };
    }

    fn asView(self: ConsumeBehavior) ConsumeBehavior {
        return switch (self) {
            .direct_clone => .direct_view,
            .direct_view, .stream_take, .stream_drop => .stream_view,
            else => self,
        };
    }

    fn source(self: ConsumeBehavior) Source {
        return switch (self) {
            .direct_clone, .direct_view => .direct,
            .stream_take_clone, .stream_take, .stream_view, .stream_drop => .stream,
        };
    }

    fn allocate(self: ConsumeBehavior) Allocate {
        return switch (self) {
            .direct_clone, .stream_take_clone => .always,
            .direct_view, .stream_take, .stream_view, .stream_drop => .avoid,
        };
    }
};

pub fn EvalState(comptime T: type) type {
    const is_ptr = @typeInfo(T) == .pointer;
    return struct {
        value: T,
        used: usize,
        owned: if (is_ptr) bool else void = if (is_ptr) false else {},

        const Self = @This();

        fn fromView(value: T, used: usize) Self {
            return .{
                .value = value,
                .used = used,
            };
        }

        fn fromOwned(value: T, used: usize) Self {
            return .{
                .value = value,
                .used = used,
                .owned = true,
            };
        }

        fn deinit(self: Self, allocator: Allocator) void {
            if (comptime !is_ptr) return;
            if (self.owned) switch (@typeInfo(T).pointer.size) {
                .One => allocator.destroy(self.value),
                .Slice => allocator.free(self.value),
                else => @compileError("unsupported pointer size"),
            };
        }
    };
}

const EvalOverlap = enum {
    none,
    partial,
    full,
};

pub fn Consumer(comptime operator: combine.Operator) type {
    const match = operator.match;
    const filter_may_skip = if (operator.filter) |f| f.behavior == .skip else false;
    const OutputState = EvalState(operator.Output());
    const MatchState = EvalState(switch (match.capacity) {
        .single => match.Input,
        .sequence => []const match.Input,
    });

    return union(enum) {
        fail,
        discard,
        ok: OutputState,

        const Self = @This();

        fn provide(source: anytype) Provider(@TypeOf(source), operator.Input(), match.Input) {
            return .{ .source = source };
        }

        pub fn evaluate(
            allocator: Allocator,
            source: anytype,
            comptime behavior: ConsumeBehavior,
            skip: behavior.Skip(),
        ) !Self {
            const matched: MatchState = switch (comptime match.capacity) {
                .single => try matchSingle(allocator, source, behavior, skip),
                .sequence => try matchSequence(allocator, source, behavior, skip),
            } orelse {
                @branchHint(.unlikely);
                return .fail;
            };

            if (comptime operator.resolve) |resolve| {
                return processResolver(allocator, source, matched, resolve, behavior);
            } else {
                return processPassthrough(allocator, source, matched, behavior);
            }
        }

        fn matchSingle(
            allocator: Allocator,
            source: anytype,
            comptime behavior: ConsumeBehavior,
            skip: behavior.Skip(),
        ) !?EvalState(match.Input) {
            const provider = provide(source);
            switch (try provider.safeReadSingle(allocator, operator.filter, behavior, skip)) {
                .filtered_skip => |state| return if (comptime filter_may_skip) state else unreachable,
                inline .filtered, .standard => |state, g| {
                    if (comptime g == .filtered and operator.filter == null) unreachable;
                    if (match.evalSingle(state.value)) {
                        if (comptime behavior.canTake()) provider.drop(state.used);
                        return state;
                    } else {
                        @branchHint(.unlikely);
                        return null;
                    }
                },
                .fail => {
                    @branchHint(.unlikely);
                    return null;
                },
            }
        }

        fn matchSequence(
            allocator: Allocator,
            source: anytype,
            comptime behavior: ConsumeBehavior,
            skip: behavior.Skip(),
        ) !?EvalState([]const match.Input) {
            const provider = provide(source);
            var sequencer = Sequencer(match.Input, operator.scratch_hint, behavior.canTake()).init(allocator, skip);
            errdefer sequencer.deinit();

            while (true) switch (try sequencer.cycle(provider, behavior, operator.filter)) {
                .filtered_skip => |item| if (comptime filter_may_skip) {
                    try sequencer.appendItem(provider, item, true);
                    continue;
                } else unreachable,
                inline .standard, .filtered => |item, t| {
                    if (comptime t == .filtered and operator.filter == null) unreachable;
                    switch (match.evalSequence(sequencer.i, item.value)) {
                        inline .next, .done_include => |g| {
                            try sequencer.appendItem(provider, item, t == .filtered);
                            if (g == .next) continue else break;
                        },
                        .done_exclude => {
                            if (sequencer.isEmpty()) {
                                @branchHint(.cold);
                                sequencer.deinit();
                                return null;
                            } else {
                                break;
                            }
                        },
                        .invalid => {
                            @branchHint(.unlikely);
                            sequencer.deinit();
                            return null;
                        },
                    }
                },
                .fail => {
                    @branchHint(.unlikely);
                    sequencer.deinit();
                    return null;
                },
            };

            return try sequencer.consume(provider);
        }

        fn processPassthrough(
            allocator: Allocator,
            source: anytype,
            matched: MatchState,
            comptime behavior: ConsumeBehavior,
        ) !Self {
            if (comptime behavior == .stream_drop) {
                return discardMatched(allocator, source, matched);
            } else {
                return passthroughOutput(allocator, behavior, matched);
            }
        }

        fn processResolver(
            allocator: Allocator,
            source: anytype,
            matched: MatchState,
            comptime resolve: combine.Resolver,
            comptime behavior: ConsumeBehavior,
        ) !Self {
            const output = resolve.eval(matched.value) orelse {
                @branchHint(.cold);
                matched.deinit(allocator);
                return .fail;
            };

            if (comptime behavior == .stream_drop) return discardMatched(allocator, source, matched);

            if (comptime canOverlap(@TypeOf(matched.value), operator.Output())) {
                switch (overlapValues(matched.value, output)) {
                    .full => return passthroughOutput(allocator, behavior, .{
                        .value = output,
                        .used = matched.used,
                        .owned = matched.owned,
                    }),
                    .partial => {
                        defer matched.deinit(allocator);
                        return .{ .ok = try cloneResolved(allocator, output, matched.used) };
                    },
                    .none => {},
                }
            }

            matched.deinit(allocator);
            return .{ .ok = .fromView(output, matched.used) };
        }

        fn discardMatched(allocator: Allocator, source: anytype, matched: MatchState) Self {
            matched.deinit(allocator);
            provide(source).drop(matched.used);
            return .discard;
        }

        fn passthroughOutput(allocator: Allocator, comptime behavior: ConsumeBehavior, state: OutputState) !Self {
            if ((comptime behavior.allocate() == .always and @TypeOf(state.owned) == bool) and !state.owned) {
                return .{ .ok = try cloneResolved(allocator, state.value, state.used) };
            } else {
                return .{ .ok = state };
            }
        }

        fn cloneResolved(allocator: Allocator, resolved: operator.Output(), used: usize) !OutputState {
            switch (@typeInfo(operator.Output())) {
                .pointer => |meta| {
                    switch (meta.size) {
                        .One => {
                            const value = try allocator.create(meta.child);
                            value.* = resolved.*;
                            return .fromOwned(value, used);
                        },
                        .Slice => return .fromOwned(try allocator.dupe(meta.child, resolved), used),
                        else => @compileError("unsupported pointer size"),
                    }
                },
                else => return .fromView(resolved, used),
            }
        }

        fn canOverlap(comptime Lhs: type, comptime Rhs: type) bool {
            return @typeInfo(Lhs) == .pointer and @typeInfo(Rhs) == .pointer;
        }

        /// Assumes both values are pointers.
        fn overlapValues(lhs: anytype, rhs: anytype) EvalOverlap {
            const lhs_bytes = switch (@typeInfo(@TypeOf(lhs)).pointer.size) {
                .One => std.mem.asBytes(lhs),
                .Slice => std.mem.sliceAsBytes(lhs),
                else => @compileError("unsupported pointer size"),
            };
            const rhs_byts = switch (@typeInfo(@TypeOf(rhs)).pointer.size) {
                .One => std.mem.asBytes(rhs),
                .Slice => std.mem.sliceAsBytes(rhs),
                else => @compileError("unsupported pointer size"),
            };
            const lhs_ptr = @intFromPtr(lhs_bytes.ptr);
            const rhs_ptr = @intFromPtr(rhs_byts.ptr);

            if (lhs_bytes.ptr == rhs_byts.ptr and lhs_bytes.len == rhs_byts.len)
                return .full
            else if (lhs_ptr >= rhs_ptr + rhs_byts.len or rhs_ptr >= lhs_ptr + lhs_bytes.len)
                return .none
            else
                return .partial;
        }
    };
}

fn Sequencer(comptime T: type, comptime scratch_hint: SizeHint, comptime can_take: bool) type {
    const Skip = if (can_take) u0 else usize;
    return struct {
        allocator: Allocator,
        i: usize = 0,
        skip: Skip = 0,
        used: usize = 0,
        scratch: Scratch(T, scratch_hint) = .{},
        scratch_active: if (can_take) void else bool = if (can_take) {} else false,

        const Self = @This();

        pub fn init(allocator: Allocator, skip: Skip) Self {
            return .{
                .skip = skip,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.scratch.deinit(self.allocator);
        }

        pub fn isEmpty(self: *Self) bool {
            return self.i == 0;
        }

        pub fn cycle(
            self: Self,
            provider: anytype,
            comptime behavior: ConsumeBehavior,
            comptime filter: ?combine.Filter,
        ) !@TypeOf(provider).Item {
            const skip = if (can_take) 0 else self.skip + self.used;
            return provider.safeReadSingle(self.allocator, filter, behavior, skip);
        }

        pub fn appendItem(self: *Self, provider: anytype, item: EvalState(T), comptime filtered: bool) !void {
            if (!can_take and filtered) {
                if (!self.scratch_active) try self.actviateScratch(provider);
                try self.scratch.appendItem(self.allocator, self.i, item.value);
            } else if (can_take or self.scratch_active) {
                try self.scratch.appendItem(self.allocator, self.i, item.value);
            }

            self.i += 1;
            self.used += item.used;
            if (can_take) provider.drop(item.used);
        }

        fn actviateScratch(self: *Self, provider: anytype) !void {
            @branchHint(.unlikely);
            std.debug.assert(self.i == self.used);
            std.debug.assert(!self.scratch_active);
            try self.scratch.appendSlice(self.allocator, 0, provider.peekSequence(self.skip, self.i));
            self.scratch_active = true;
        }

        pub fn consume(self: *Self, provider: anytype) !EvalState([]const T) {
            if (can_take or self.scratch_active) {
                return .fromOwned(try self.scratch.consume(self.allocator), self.used);
            } else {
                return .fromView(provider.peekSequence(self.skip, self.used), self.used);
            }
        }
    };
}

fn Provider(comptime Source: type, comptime In: type, comptime Out: type) type {
    const is_direct = @typeInfo(Source) == .pointer and @typeInfo(Source).pointer.size == .Slice;
    return struct {
        source: Source,

        const Self = @This();

        pub const Item = union(enum) {
            /// Unfiltered item.
            standard: EvalState(Out),
            /// Filtered item.
            filtered: EvalState(Out),
            /// Filtered item should skip matching.
            filtered_skip: EvalState(Out),
            /// Invalid item or filter.
            fail,
        };

        pub fn reserveSingle(self: Self, i: usize) !void {
            if (!is_direct) {
                try self.source.reserve(i + 1);
            } else if (i >= self.source.len) {
                return error.EndOfStream;
            }
        }

        pub fn reserveSequence(self: Self, i: usize, len: usize) !void {
            if (!is_direct) {
                try self.source.reserve(i + len);
            } else if (i + len > self.source.len) {
                return error.EndOfStream;
            }
        }

        /// Assumes valid bounds.
        pub fn peekSingle(self: Self, i: usize) In {
            return if (is_direct) self.source[i] else return self.source.peekByte(i);
        }

        /// Assumes valid bounds.
        pub fn peekSequence(self: Self, i: usize, len: usize) []const In {
            return if (is_direct) self.source[i..][0..len] else self.source.peekSlice(i, len);
        }

        /// Assumes valid bounds.
        pub fn drop(self: Self, len: usize) void {
            if (!is_direct) self.source.drop(len);
        }

        pub fn safeReadSingle(
            self: Self,
            allocator: Allocator,
            comptime filter: ?combine.Filter,
            comptime behavior: ConsumeBehavior,
            i: usize,
        ) !Item {
            if (comptime filter) |f| {
                comptime f.operator.validate(In, Out);
                switch (try Consumer(f.operator).evaluate(allocator, self.source, comptime behavior.asView(), i)) {
                    .ok => |consume| return switch (comptime f.behavior) {
                        .skip => .{ .filtered_skip = consume },
                        else => .{ .filtered = consume },
                    },
                    .fail => {
                        if (comptime f.behavior == .fail) {
                            @branchHint(.unlikely);
                            return .fail;
                        }
                        // Else, safe behavior will continue as if there was no filter...
                    },
                    .discard => unreachable,
                }
            }

            try self.reserveSingle(i);
            return .{ .standard = .fromView(self.peekSingle(i), 1) };
        }
    };
}

fn Scratch(comptime T: type, comptime size_hint: SizeHint) type {
    const Buffer = switch (size_hint) {
        .dynamic => std.ArrayListUnmanaged(T),
        .bound => |max| std.BoundedArray(T, max),
        .exact => |len| [len]T,
    };

    return struct {
        buffer: Buffer = switch (size_hint) {
            .exact => undefined,
            inline else => .{},
        },

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            switch (size_hint) {
                .dynamic => self.buffer.deinit(allocator),
                else => {},
            }
        }

        pub fn appendItem(self: *Self, allocator: Allocator, i: usize, item: T) !void {
            switch (size_hint) {
                .dynamic => {
                    std.debug.assert(i == self.buffer.items.len);
                    try self.buffer.append(allocator, item);
                },
                .bound => {
                    std.debug.assert(i == self.buffer.len);
                    try self.buffer.append(item);
                },
                .exact => self.buffer[i] = item,
            }
        }

        pub fn appendSlice(self: *Self, allocator: Allocator, i: usize, items: []const T) !void {
            switch (size_hint) {
                .dynamic => {
                    std.debug.assert(i == self.buffer.items.len);
                    try self.buffer.appendSlice(allocator, items);
                },
                .bound => {
                    std.debug.assert(i == self.buffer.len);
                    try self.buffer.appendSlice(items);
                },
                .exact => @memcpy(self.buffer[i..][0..items.len], items),
            }
        }

        pub fn consume(self: *Self, allocator: Allocator) ![]const T {
            return switch (size_hint) {
                .dynamic => self.buffer.toOwnedSlice(allocator),
                .bound => try allocator.dupe(T, self.buffer.constSlice()),
                .exact => try allocator.dupe(T, &self.buffer),
            };
        }
    };
}

test "Scratch: exact" {
    var scratch = Scratch(u8, .{ .exact = 3 }){};
    try scratch.appendItem(undefined, 2, 'c');
    try scratch.appendSlice(undefined, 0, "ab");

    const slice = try scratch.consume(test_alloc);
    defer test_alloc.free(slice);
    try testing.expectEqualStrings("abc", slice);
}

test "Scratch: bound" {
    var scratch = Scratch(u8, .{ .bound = 6 }){};
    try scratch.appendItem(undefined, 0, 'a');
    try scratch.appendSlice(undefined, 1, "bc");

    const slice = try scratch.consume(test_alloc);
    defer test_alloc.free(slice);
    try testing.expectEqualStrings("abc", slice);
}

test "Scratch: dynamic" {
    var scratch = Scratch(u8, .dynamic){};
    errdefer scratch.deinit(test_alloc);

    try scratch.appendItem(test_alloc, 0, 'a');
    try scratch.appendSlice(test_alloc, 1, "bc");

    const slice = try scratch.consume(test_alloc);
    defer test_alloc.free(slice);
    try testing.expectEqualStrings("abc", slice);
}

test "Consumer: match single" {
    var reader = TestingReader{ .buffer = "abc" };
    try TestingConsumer(BuildOp.matchSingle(.ok)).expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.fail)).expectFail().evaluate(&reader, .{ .view = 1 });

    // Propogate reader failure
    reader.reset(.{ .fail = .{ .cursor = 0 } });
    try TestingConsumer(BuildOp.matchSingle(.ok)).expectReaderError().evaluate(&reader, .{ .view = 1 });
}

test "Consumer: match sequence" {
    var reader = TestingReader{ .buffer = "abcd" };
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .position = 2 }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.invalid, .{ .position = 2 }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Exclude when i == 0
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .position = 0 }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Propogate reader failure
    reader.reset(.{ .fail = .{ .cursor = 0 } });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .position = 2 }))
        .expectReaderError().evaluate(&reader, .{ .view = 1 });
}

test "Consumer: resolve" {
    var reader = TestingReader{ .buffer = "abcd" };

    // Single
    try TestingConsumer(BuildOp.matchSingle(.ok).resolve(.passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.ok).resolve(.{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.ok).resolve(.fail))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Sequence
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).resolve(.passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).resolve(.{ .constant_char = 'x' }))
        .expectSuccess('x', 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).resolve(.fail))
        .expectFail().evaluate(&reader, .{ .view = 1 });
}

test "Consumer: take single" {
    var reader = TestingReader{ .buffer = "ab" };
    try TestingConsumer(BuildOp.matchSingle(.fail)).expectFail().evaluate(&reader, .take);
    try TestingConsumer(BuildOp.matchSingle(.ok)).expectSuccess('a', 1).evaluate(&reader, .take);
    try TestingConsumer(BuildOp.matchSingle(.ok)).expectSuccess('b', 1).evaluate(&reader, .take);
    try TestingConsumer(BuildOp.matchSingle(.ok)).expectReaderError().evaluate(&reader, .take);
}

test "Consumer: take sequence" {
    var reader = TestingReader{};
    try TestingConsumer(BuildOp.matchSequence(.invalid, .{ .position = 1 }))
        .expectFail().evaluate(&reader, .take);
    try reader.expectCursor(1); // Takes the first char, then the second fails

    reader.reset(.{ .buffer = "abcde" });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .position = 2 }))
        .expectSuccess("ab", 2).evaluate(&reader, .take);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }))
        .expectSuccess("cd", 2).evaluate(&reader, .take);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }))
        .expectReaderError().evaluate(&reader, .take);
    try reader.expectCursor(5); // Takes the first char, then the second fails
}

test "Consumer: clone" {
    var reader = TestingReader{};
    try TestingConsumer(BuildOp.matchSequence(.invalid, .{ .position = 1 }))
        .expectFail().evaluate(&reader, .clone);
    try reader.expectCursor(1); // Takes the first char, then the second fails

    reader.reset(.{ .buffer = "abcde" });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .position = 2 }))
        .expectSuccess("ab", 2).evaluate(&reader, .clone);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }))
        .expectSuccess("cd", 2).evaluate(&reader, .clone);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }))
        .expectReaderError().evaluate(&reader, .clone);
    try reader.expectCursor(5); // Takes the first char, then the second fails
}

test "Consumer: drop" {
    var reader = TestingReader{};

    // Unresolved

    try TestingConsumer(BuildOp.matchSingle(.ok)).expectSuccess(undefined, 1)
        .evaluate(&reader, .drop);
    try reader.expectCursor(1);

    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }))
        .expectSuccess(undefined, 2).evaluate(&reader, .drop);
    try reader.expectCursor(3);

    // Resolved

    try TestingConsumer(BuildOp.matchSingle(.ok).resolve(.passthrough)).expectSuccess(undefined, 1)
        .evaluate(&reader, .drop);
    try reader.expectCursor(4);

    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).resolve(.{ .constant_char = 'x' }))
        .expectSuccess(undefined, 2).evaluate(&reader, .drop);
    try reader.expectCursor(6);
}

test "Consumer: filter single" {
    var reader = TestingReader{ .buffer = "abc" };

    // Safe
    try TestingConsumer(BuildOp.matchSingle(.ok).filterSingle(.safe, .ok, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.ok).filterSingle(.safe, .ok, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.ok).filterSingle(.safe, .fail, .{ .constant_char = 'x' }))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });

    // Fail
    try TestingConsumer(BuildOp.matchSingle(.ok).filterSingle(.fail, .ok, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.ok).filterSingle(.fail, .ok, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.ok).filterSingle(.fail, .fail, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Skip
    try TestingConsumer(BuildOp.matchSingle(.{ .fail_value = 'b' }).filterSingle(.skip, .ok, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.{ .fail_value = 'x' }).filterSingle(.skip, .ok, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.{ .fail_value = 'x' }).filterSingle(.skip, .fail, .{ .constant_char = 'x' }))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSingle(.{ .fail_value = 'b' }).filterSingle(.skip, .fail, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });
}

test "Consumer: filter sequence" {
    var reader = TestingReader{ .buffer = "abcd" };

    // Safe
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).filterSingle(.safe, .ok, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).filterSingle(.safe, .ok, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).filterSingle(.safe, .fail, .{ .constant_char = 'x' }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });

    // Fail
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).filterSingle(.fail, .ok, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).filterSingle(.fail, .ok, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .position = 1 }).filterSingle(.fail, .fail, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Skip
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .value = 'c' }).filterSingle(.skip, .{ .fail_value = 'c' }, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .value = 'c' }).filterSingle(.skip, .{ .fail_value = 'c' }, .{ .constant_char = 'x' }))
        .expectSuccess("xc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.invalid, .{ .value = 'c' }).filterSingle(.skip, .{ .fail_value = 'c' }, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });
}

fn TestingConsumer(comptime op: BuildOp) type {
    const operator = op.build();
    return struct {
        expected: ExpectState,

        const Self = @This();
        const ExpectState = union(enum) {
            stream_error,
            eval_fail,
            success: EvalState(operator.Output()),
        };

        pub const EvalStream = union(enum) {
            clone,
            take,
            view: usize,
            drop,
        };

        pub fn expectReaderError() Self {
            return .{ .expected = .stream_error };
        }

        pub fn expectFail() Self {
            return .{ .expected = .eval_fail };
        }

        pub fn expectSuccess(value: operator.Output(), used: usize) Self {
            return .{ .expected = .{
                .success = .{
                    .used = used,
                    .value = value,
                },
            } };
        }

        pub fn evaluate(self: *const Self, reader: *TestingReader, comptime behavior: EvalStream) !void {
            const behave, const skip = switch (behavior) {
                .clone => .{ .stream_take_clone, 0 },
                .take => .{ .stream_take, 0 },
                .view => |skip| .{ .stream_view, skip },
                .drop => .{ .stream_drop, 0 },
            };

            const inital_cursor = reader.countConsumed();
            const evaluated = Consumer(operator).evaluate(test_alloc, reader, behave, skip);
            switch (self.expected) {
                .stream_error => return testing.expectError(error.EndOfStream, evaluated),
                .eval_fail => return testing.expectEqual(.fail, try evaluated),
                .success => |expected| {
                    const actual = try evaluated;

                    switch (behavior) {
                        .drop => try expectActiveTag(.discard, actual),
                        else => {
                            try expectActiveTag(.ok, actual);
                            defer actual.ok.deinit(test_alloc);
                            try expectValue(expected.value, actual.ok.value);
                        },
                    }

                    check: switch (behavior) {
                        .view => {
                            try testing.expectEqual(expected.used, actual.ok.used);
                            try testing.expectEqual(inital_cursor, reader.countConsumed());
                        },
                        .clone => {
                            const is_ptr = @typeInfo(operator.Output()) == .pointer;
                            if (is_ptr) try testing.expectEqual(true, actual.ok.owned);
                            continue :check .take;
                        },
                        else => try testing.expectEqual(inital_cursor + expected.used, reader.countConsumed()),
                    }
                },
            }
        }

        fn expectActiveTag(expected: anytype, actual: anytype) !void {
            try testing.expectEqual(expected, std.meta.activeTag(actual));
        }

        fn expectValue(expected: anytype, actual: anytype) !void {
            switch (@TypeOf(expected, actual)) {
                u8 => try testing.expectEqualStrings(&.{expected}, &.{actual}),
                []const u8 => try testing.expectEqualStrings(expected, actual),
                else => try testing.expectEqual(expected, actual),
            }
        }
    };
}
