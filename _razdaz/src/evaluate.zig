const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const Allocator = std.mem.Allocator;
const combine = @import("combine.zig");
const BuildOp = @import("testing.zig").TestingOperator;
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

    inline fn Skip(comptime self: ConsumeBehavior) type {
        return switch (self) {
            .direct_clone, .direct_view, .stream_view => usize,
            .stream_take_clone, .stream_take, .stream_drop => u0,
        };
    }

    inline fn canTake(comptime self: ConsumeBehavior) bool {
        return switch (self) {
            .stream_take_clone, .stream_take => true,
            else => false,
        };
    }

    inline fn asView(comptime self: ConsumeBehavior) ConsumeBehavior {
        return switch (self) {
            .direct_clone => .direct_view,
            .direct_view, .stream_take, .stream_drop => .stream_view,
            else => self,
        };
    }

    inline fn source(comptime self: ConsumeBehavior) Source {
        return switch (self) {
            .direct_clone, .direct_view => .direct,
            .stream_take_clone, .stream_take, .stream_view, .stream_drop => .stream,
        };
    }

    inline fn allocate(comptime self: ConsumeBehavior) Allocate {
        return switch (self) {
            .direct_clone, .stream_take_clone => .always,
            .direct_view, .stream_take, .stream_view, .stream_drop => .avoid,
        };
    }
};

pub fn Evaluate(comptime operator: combine.Operator) type {
    const match = operator.match;
    return union(enum) {
        fail,
        discard,
        ok: EvalState(operator.Output()),

        const Self = @This();

        pub fn at(
            allocator: Allocator,
            source: anytype,
            comptime behavior: ConsumeBehavior,
            skip: behavior.Skip(),
        ) !Self {
            const Evaluator = switch (match.capacity) {
                .single => Single(operator, @TypeOf(source), behavior),
                .sequence => Sequence(operator, @TypeOf(source), behavior),
            };
            return Evaluator.evaluate(allocator, source, skip);
        }
    };
}

pub fn EvalState(comptime T: type) type {
    return struct {
        value: T,
        used: usize,
        owned: if (can_own) bool else void = if (can_own) false else {},

        const Self = @This();
        pub const can_own = @typeInfo(T) == .pointer;

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

        pub inline fn isOwned(self: Self) bool {
            return (comptime can_own) and self.owned;
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            if (self.isOwned()) switch (@typeInfo(T).pointer.size) {
                .One => allocator.destroy(self.value),
                .Slice => allocator.free(self.value),
                else => @compileError("unsupported pointer size"),
            };
        }
    };
}

fn Single(comptime op: combine.Operator, comptime Source: type, comptime behavior: ConsumeBehavior) type {
    const can_own = @typeInfo(op.match.Input) == .pointer;
    return struct {
        allocator: Allocator,
        provider: Provider(Source, op.Input(), op.match.Input),
        used: usize = 0,
        scratch: op.match.Input = undefined,
        owned: if (can_own) bool else void = if (can_own) false else {},

        const Self = @This();
        const Process = Processor(
            op.match.Input,
            op.Output(),
            if (behavior == .stream_drop) .discard else if (behavior.allocate() == .always) .clone else .standard,
            .{
                .deinitScratch = deinitScratch,
                .consumeUsed = consumeUsed,
                .isOwned = isOwned,
            },
        );

        pub fn evaluate(allocator: Allocator, source: Source, skip: behavior.Skip()) !Evaluate(op) {
            var self = Self{
                .allocator = allocator,
                .provider = .{ .source = source },
            };

            if (try self.match(skip)) switch (try Process.consume(allocator, &self, self.scratch, op.resolve)) {
                .discard => return .discard,
                .view => |output| if (comptime !can_own or behavior.allocate() == .avoid) {
                    return .{ .ok = .fromView(output, self.used) };
                } else unreachable,
                .owned => |output| if (comptime can_own) {
                    return .{ .ok = .fromOwned(output, self.used) };
                } else unreachable,
                .fail => return .fail,
            } else return .fail;
        }

        fn match(self: *Self, skip: behavior.Skip()) !bool {
            switch (try self.provider.readAt(self.allocator, op.filter, behavior, skip)) {
                .filtered => |item| {
                    if (comptime op.filter) |f| return self.setItem(item, f.behavior != .skip) else unreachable;
                },
                .standard => |item| return self.setItem(item, true),
                .fail => return false,
            }
        }

        fn setItem(self: *Self, item: EvalState(op.match.Input), comptime eval: bool) bool {
            if (eval and !op.match.evalSingle(item.value)) return false;
            if (behavior.canTake()) self.provider.drop(item.used);
            self.used = item.used;
            self.owned = item.owned;
            self.scratch = item.value;
            return true;
        }

        fn isOwned(ctx: *const anyopaque) bool {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            return if (comptime can_own) self.owned else false;
        }

        fn consumeUsed(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.provider.drop(self.used);
        }

        fn deinitScratch(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (@typeInfo(op.match.Input)) {
                .pointer => |meta| switch (meta.size) {
                    .One => self.allocator.destroy(self.scratch),
                    .Slice => self.allocator.free(self.scratch),
                    else => @compileError("unsupported pointer size"),
                },
                else => {},
            }
        }
    };
}

fn Sequence(comptime op: combine.Operator, comptime Source: type, comptime behavior: ConsumeBehavior) type {
    const use_scratch = op.filter != null or behavior.canTake();
    return struct {
        allocator: Allocator,
        used: usize = 0,
        provider: Provider(Source, op.Input(), op.match.Input),
        scratch: Scratch(op.match.Input, op.match.capacity.sequence) = .{},
        active_scratch: if (use_scratch) bool else void = if (use_scratch) behavior.canTake() else {},

        const Self = @This();
        const Process = Processor(
            []const op.match.Input,
            op.Output(),
            if (behavior == .stream_drop) .discard else if (behavior.allocate() == .always) .clone else .standard,
            .{
                .deinitScratch = deinitScratch,
                .consumeUsed = consumeUsed,
                .isOwned = isOwned,
            },
        );

        inline fn hasScratch(self: *const Self) bool {
            return use_scratch and self.active_scratch;
        }

        pub fn evaluate(allocator: Allocator, source: Source, skip: behavior.Skip()) !Evaluate(op) {
            var self = Self{
                .allocator = allocator,
                .provider = .{ .source = source },
            };

            errdefer self.scratch.deinit(allocator);

            if (!try self.match(skip)) {
                self.scratch.deinit(allocator);
                return .fail;
            }

            const slice = if (self.hasScratch())
                self.scratch.view()
            else
                self.provider.viewSlice(skip, self.used);

            switch (try Process.consume(allocator, &self, slice, op.resolve)) {
                .discard => return .discard,
                .view => |output| if (behavior.allocate() == .avoid) {
                    if (self.hasScratch()) {
                        if (@typeInfo(op.Output()) == .pointer) {
                            const owned = try self.scratch.consume(allocator);
                            return .{ .ok = .fromOwned(owned, self.used) };
                        }

                        self.scratch.deinit(allocator);
                    }

                    return .{ .ok = .fromView(output, self.used) };
                } else unreachable,
                .owned => |output| {
                    if (@typeInfo(op.Output()) != .pointer) unreachable;
                    self.scratch.deinit(allocator);
                    return .{ .ok = .fromOwned(output, self.used) };
                },
                .fail => return .fail,
            }
        }

        fn match(self: *Self, skip: behavior.Skip()) !bool {
            var i: usize = 0;
            while (true) : (i += 1) {
                const skip_amount = if (behavior.canTake()) 0 else skip + self.used;
                switch (try self.provider.readAt(self.allocator, op.filter, behavior, skip_amount)) {
                    inline .standard, .filtered => |item, t| if (comptime t == .standard or op.filter != null) {
                        defer item.deinit(self.allocator);
                        if (comptime t == .filtered and op.filter.?.behavior == .skip) {
                            try self.appendItem(skip, i, item, true);
                            continue;
                        } else switch (op.match.evalSequence(i, item.value)) {
                            .next => {
                                @branchHint(.likely);
                                try self.appendItem(skip, i, item, t == .filtered);
                                continue;
                            },
                            .done_include => {
                                try self.appendItem(skip, i, item, t == .filtered);
                                break;
                            },
                            .done_exclude => if (i > 0) break else {
                                @branchHint(.cold);
                                return false;
                            },
                            .invalid => return false,
                        }
                    } else unreachable,
                    .fail => {
                        @branchHint(.unlikely);
                        return false;
                    },
                }
            }

            return true;
        }

        fn appendItem(
            self: *Self,
            skip: behavior.Skip(),
            i: usize,
            item: EvalState(op.match.Input),
            comptime filtered: bool,
        ) !void {
            if (filtered and !(behavior.canTake() or self.hasScratch())) {
                @branchHint(.unlikely);
                std.debug.assert(i == self.used);
                try self.scratch.appendSlice(self.allocator, 0, self.provider.viewSlice(skip, i));
                self.active_scratch = true;
            }

            if (filtered or behavior.canTake() or self.hasScratch()) try self.scratch.appendItem(self.allocator, i, item.value);
            if (behavior.canTake()) self.provider.drop(item.used);
            self.used += item.used;
        }

        fn consumeUsed(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.provider.drop(self.used);
        }

        fn deinitScratch(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.scratch.deinit(self.allocator);
            if (use_scratch) self.active_scratch = false;
        }

        fn isOwned(_: *const anyopaque) bool {
            return false;
        }
    };
}

const ProcessVTable = struct {
    deinitScratch: fn (ctx: *anyopaque) void,
    consumeUsed: fn (ctx: *anyopaque) void,
    isOwned: fn (ctx: *const anyopaque) bool,
};
const ProcessOverlap = enum { none, partial, full };
const ProcessBehavior = enum { standard, discard, clone };

fn Processor(
    comptime In: type,
    comptime Out: type,
    comptime behavior: ProcessBehavior,
    comptime vtable: ProcessVTable,
) type {
    return struct {
        ctx: *anyopaque,
        allocator: Allocator,

        const Self = @This();
        const State = union(enum) { fail, discard, view: Out, owned: Out };
        const can_overlap = @typeInfo(In) == .pointer and @typeInfo(Out) == .pointer;

        pub fn consume(allocator: Allocator, ctx: *anyopaque, input: In, comptime resolver: ?combine.Resolver) !State {
            const self = Self{
                .allocator = allocator,
                .ctx = ctx,
            };

            if (comptime resolver) |r| {
                return self.resolve(input, r);
            } else if (comptime behavior == .discard) {
                return self.consumeScratch();
            } else {
                return self.consumeOrView(input);
            }
        }

        fn resolve(self: Self, input: In, comptime resolver: combine.Resolver) !State {
            const output = resolver.eval(input) orelse {
                @branchHint(.cold);
                vtable.deinitScratch(self.ctx);
                return .fail;
            };

            if (comptime behavior == .discard) {
                return self.consumeScratch();
            } else if (comptime !can_overlap) {
                vtable.deinitScratch(self.ctx);
                return .{ .view = output };
            } else switch (overlapValues(input, output)) {
                .full => return self.consumeOrView(output),
                .partial => {
                    defer vtable.deinitScratch(self.ctx);
                    return self.cloneResolved(output);
                },
                .none => {
                    vtable.deinitScratch(self.ctx);
                    return .{ .view = output };
                },
            }
        }

        fn consumeScratch(self: Self) State {
            vtable.deinitScratch(self.ctx);
            vtable.consumeUsed(self.ctx);
            return .discard;
        }

        fn consumeOrView(self: Self, output: Out) !State {
            const owned = vtable.isOwned(self.ctx);
            if ((comptime behavior == .clone) and !owned) {
                return self.cloneResolved(output);
            } else if (owned) {
                return .{ .owned = output };
            } else {
                return .{ .view = output };
            }
        }

        fn cloneResolved(self: Self, output: Out) !State {
            switch (@typeInfo(Out)) {
                .pointer => |meta| switch (meta.size) {
                    .One => {
                        const value = try self.allocator.create(meta.child);
                        value.* = output.*;
                        return .{ .owned = value };
                    },
                    .Slice => return .{ .owned = try self.allocator.dupe(meta.child, output) },
                    else => @compileError("unsupported pointer size"),
                },
                else => return .{ .view = output },
            }
        }

        /// Assumes both values are pointers.
        fn overlapValues(input: In, output: Out) ProcessOverlap {
            const in_bytes = switch (@typeInfo(In).pointer.size) {
                .One => std.mem.asBytes(input),
                .Slice => std.mem.sliceAsBytes(input),
                else => @compileError("unsupported pointer size"),
            };
            const out_byts = switch (@typeInfo(Out).pointer.size) {
                .One => std.mem.asBytes(output),
                .Slice => std.mem.sliceAsBytes(output),
                else => @compileError("unsupported pointer size"),
            };

            const in_ptr = @intFromPtr(in_bytes.ptr);
            if (in_bytes.ptr == out_byts.ptr and in_bytes.len == out_byts.len) return .full;

            const out_ptr = @intFromPtr(out_byts.ptr);
            if (in_ptr >= out_ptr + out_byts.len or out_ptr >= in_ptr + in_bytes.len) return .none;

            return .partial;
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
            /// Invalid item or filter.
            fail,
        };

        pub fn reserveItem(self: Self, i: usize) !void {
            if (!is_direct) {
                try self.source.reserve(i + 1);
            } else if (i >= self.source.len) {
                return error.EndOfStream;
            }
        }

        pub fn reserveSlice(self: Self, i: usize, len: usize) !void {
            if (!is_direct) {
                try self.source.reserve(i + len);
            } else if (i + len > self.source.len) {
                return error.EndOfStream;
            }
        }

        /// Assumes valid bounds.
        pub fn viewItem(self: Self, i: usize) In {
            return if (is_direct) self.source[i] else return self.source.peekByte(i);
        }

        /// Assumes valid bounds.
        pub fn viewSlice(self: Self, i: usize, len: usize) []const In {
            return if (is_direct) self.source[i..][0..len] else self.source.peekSlice(i, len);
        }

        /// Assumes valid bounds.
        pub fn drop(self: Self, len: usize) void {
            if (!is_direct) self.source.drop(len);
        }

        pub fn readAt(
            self: Self,
            allocator: Allocator,
            comptime filter: ?combine.Filter,
            comptime behavior: ConsumeBehavior,
            i: usize,
        ) !Item {
            if (comptime filter) |f| {
                comptime f.operator.validate(In, Out);
                switch (try Evaluate(f.operator).at(allocator, self.source, comptime behavior.asView(), i)) {
                    .ok => |state| return .{ .filtered = state },
                    .fail => {
                        if (comptime f.behavior == .fail) return .fail;
                        try self.reserveItem(i);
                        return .{ .standard = .fromView(self.viewItem(i), 1) };
                    },
                    .discard => unreachable,
                }
            } else {
                try self.reserveItem(i);
                return .{ .standard = .fromView(self.viewItem(i), 1) };
            }
        }
    };
}

fn Scratch(comptime T: type, comptime size_hint: combine.SizeHint) type {
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

        pub fn consume(self: *Self, allocator: Allocator) ![]const T {
            return switch (size_hint) {
                .dynamic => self.buffer.toOwnedSlice(allocator),
                .bound => try allocator.dupe(T, self.buffer.constSlice()),
                .exact => try allocator.dupe(T, &self.buffer),
            };
        }

        pub fn view(self: Self) []const T {
            return switch (size_hint) {
                .dynamic => self.buffer.items,
                .bound => self.buffer.constSlice(),
                .exact => &self.buffer,
            };
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
    var scratch = Scratch(u8, .max(6)){};
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
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.invalid, .{ .index = 2 }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Fail when exclude at i == 0
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .index = 0 }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Propogate reader failure
    reader.reset(.{ .fail = .{ .cursor = 0 } });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
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
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.{ .constant_char = 'x' }))
        .expectSuccess('x', 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.fail))
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
    try TestingConsumer(BuildOp.matchSequence(.invalid, .{ .index = 1 }))
        .expectFail().evaluate(&reader, .take);
    try reader.expectCursor(1); // Takes the first char, then the second fails

    reader.reset(.{ .buffer = "abcde" });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
        .expectSuccess("ab", 2).evaluate(&reader, .take);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess("cd", 2).evaluate(&reader, .take);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectReaderError().evaluate(&reader, .take);
    try reader.expectCursor(5); // Takes the first char, then the second fails
}

test "Consumer: clone" {
    var reader = TestingReader{};
    try TestingConsumer(BuildOp.matchSequence(.invalid, .{ .index = 1 }))
        .expectFail().evaluate(&reader, .clone);
    try reader.expectCursor(1); // Takes the first char, then the second fails

    reader.reset(.{ .buffer = "abcde" });
    try TestingConsumer(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
        .expectSuccess("ab", 2).evaluate(&reader, .clone);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess("cd", 2).evaluate(&reader, .clone);
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectReaderError().evaluate(&reader, .clone);
    try reader.expectCursor(5); // Takes the first char, then the second fails
}

test "Consumer: drop" {
    var reader = TestingReader{};

    // Unresolved

    try TestingConsumer(BuildOp.matchSingle(.ok)).expectSuccess(undefined, 1)
        .evaluate(&reader, .drop);
    try reader.expectCursor(1);

    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess(undefined, 2).evaluate(&reader, .drop);
    try reader.expectCursor(3);

    // Resolved

    try TestingConsumer(BuildOp.matchSingle(.ok).resolve(.passthrough)).expectSuccess(undefined, 1)
        .evaluate(&reader, .drop);
    try reader.expectCursor(4);

    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.{ .constant_char = 'x' }))
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
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.safe, .ok, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.safe, .ok, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.safe, .fail, .{ .constant_char = 'x' }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });

    // Fail
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fail, .ok, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fail, .ok, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingConsumer(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fail, .fail, .{ .constant_char = 'x' }))
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
            const evaluated = Evaluate(operator).at(test_alloc, reader, behave, skip);
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
                else => try testing.expectEqualDeep(expected, actual),
            }
        }
    };
}
