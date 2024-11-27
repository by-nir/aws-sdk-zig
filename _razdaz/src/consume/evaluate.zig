const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const Allocator = std.mem.Allocator;
const combine = @import("../combine.zig");
const BuildOp = @import("../testing.zig").TestingOperator;
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

        pub fn at(
            allocator: Allocator,
            source: anytype,
            comptime behavior: ConsumeBehavior,
            skip: behavior.Skip(),
        ) !@This() {
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
    const Padding = if (op.alignment == null) u0 else usize;
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
                .deinit = processDeinit,
                .discard = processDiscard,
                .ownership = processOwnership,
            },
        );

        pub fn evaluate(allocator: Allocator, source: Source, skip: behavior.Skip()) !Evaluate(op) {
            var self = Self{
                .allocator = allocator,
                .provider = .{ .source = source },
            };

            const padding: Padding = blk: {
                const alignment = op.alignment orelse break :blk 0;
                const addr = source.countConsumed() + skip;
                break :blk std.mem.alignForward(usize, addr, alignment) - addr;
            };

            if (!try self.match(skip, padding)) return .fail;

            const process = Process{
                .ctx = &self,
                .allocator = allocator,
            };
            switch (try process.consume(self.scratch, op.resolve)) {
                .discard => return .discard,
                .view => |output| if (comptime !can_own or behavior.allocate() == .avoid) {
                    return .{ .ok = .fromView(output, self.used) };
                } else unreachable,
                .owned => |output| if (comptime can_own) {
                    return .{ .ok = .fromOwned(output, self.used) };
                } else unreachable,
                .fail => return .fail,
            }
        }

        fn match(self: *Self, skip: behavior.Skip(), pad: Padding) !bool {
            switch (try self.provider.readAt(self.allocator, op.filter, behavior, skip + pad)) {
                .filtered => |item| if (comptime op.filter) |f| {
                    return self.setItem(item, pad, f.behavior == .override);
                } else unreachable,
                .standard => |item| return self.setItem(item, pad, false),
                .fail => return false,
            }
        }

        fn setItem(self: *Self, item: EvalState(op.match.Input), pad: Padding, comptime skip_eval: bool) bool {
            const success = skip_eval or op.match.evalSingle(item.value);
            if (success) {
                self.used = item.used + pad;
                self.owned = item.owned;
                self.scratch = item.value;
                if (behavior.canTake()) self.provider.drop(self.used);
            }
            return success;
        }

        fn processOwnership(ctx: *const anyopaque) ProcessOwnership {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            return if (can_own and self.owned) .owned else .view;
        }

        fn processDiscard(ctx: *const anyopaque) void {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            self.provider.drop(self.used);
        }

        fn processDeinit(ctx: *anyopaque) void {
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
    const scratch_hint = blk: {
        const hint = op.match.capacity.sequence;
        switch (hint) {
            .exact => |n| if (op.resolve) |r| if (r.behavior.isPartial()) break :blk .{ .bound = n },
            else => {},
        }
        break :blk hint;
    };
    const use_scratch = behavior.canTake() or op.filter != null or (if (op.resolve) |r| r.behavior.isEach() else false);
    const proc_behave = if (behavior == .stream_drop) .discard else if (behavior.allocate() == .always) .clone else .standard;

    return struct {
        allocator: Allocator,
        used: usize = 0,
        padding: if (op.alignment == null or behavior.canTake()) u0 else usize = 0,
        provider: Provider(Source, op.Input(), op.match.Input),
        scratch: Scratch(op.match.Input, scratch_hint) = .{},
        active_scratch: if (use_scratch) bool else void = if (use_scratch) behavior.canTake() else {},

        const Self = @This();
        const Process = Processor([]const op.match.Input, op.Output(), proc_behave, proc_table);
        const proc_table = ProcessVTable{
            .deinit = processDeinit,
            .discard = processDiscard,
            .consume = processConsume,
            .ownership = processOwnership,
        };

        inline fn hasScratch(self: *const Self) bool {
            return use_scratch and self.active_scratch;
        }

        fn processor(self: *Self) Process {
            return .{
                .ctx = self,
                .allocator = self.allocator,
            };
        }

        fn view(self: *const Self, skip: behavior.Skip()) []const op.match.Input {
            if (self.hasScratch()) {
                return self.scratch.view();
            } else {
                return self.provider.viewSlice(skip + self.padding, self.used);
            }
        }

        pub fn evaluate(allocator: Allocator, source: Source, skip: behavior.Skip()) !Evaluate(op) {
            var self = Self{
                .allocator = allocator,
                .provider = .{ .source = source },
            };
            errdefer self.scratch.deinit(allocator);

            if (op.alignment) |alignment| {
                const addr = source.countConsumed() + skip;
                const pad = std.mem.alignForward(usize, addr, alignment) - addr;
                if (behavior.canTake()) {
                    self.provider.drop(pad);
                } else {
                    self.padding = pad;
                }
            }

            var i: usize = 0;
            while (true) : (i += 1) {
                const skip_amount = if (behavior.canTake()) 0 else skip + self.padding + self.used;
                switch (try self.provider.readAt(self.allocator, op.filter, behavior, skip_amount)) {
                    inline .standard, .filtered => |item, t| if (comptime t == .standard or op.filter != null) {
                        defer item.deinit(self.allocator);
                        const is_filtered = t == .filtered;
                        if (comptime is_filtered and op.filter.?.behavior == .override) {
                            if (try self.resolveCycle(skip, i, item, is_filtered)) |out| return out else continue;
                        } else switch (op.match.evalSequence(i, item.value)) {
                            .next => {
                                @branchHint(.likely);
                                if (try self.resolveCycle(skip, i, item, is_filtered)) |out| return out else continue;
                            },
                            .done_include => return self.resolveLast(skip, i, item, is_filtered),
                            .done_exclude => {
                                std.debug.assert(i > 0);
                                return self.resolveExclude(skip);
                            },
                            .invalid => {
                                @branchHint(.unlikely);
                                self.scratch.deinit(self.allocator);
                                return .fail;
                            },
                        }
                    } else unreachable,
                    .fail => {
                        if (comptime if (op.filter) |f| f.behavior.isBreaking() else false) {
                            return self.resolveExclude(skip);
                        } else {
                            @branchHint(.unlikely);
                            self.scratch.deinit(self.allocator);
                            return .fail;
                        }
                    },
                }
            }
        }

        fn resolveCycle(
            self: *Self,
            skip: behavior.Skip(),
            i: usize,
            item: EvalState(op.match.Input),
            comptime is_filtered: bool,
        ) !?Evaluate(op) {
            if (comptime op.resolve) |resolve| behave: switch (comptime resolve.behavior) {
                .partial_defer => |min| if (i >= min) continue :behave .partial,
                .partial => if (comptime resolve.Input == []const op.match.Input) {
                    try self.appendItem(skip, i, item.value, item.used, is_filtered);

                    const input = self.view(skip);
                    const output = resolve.eval(input) orelse return null;
                    return try self.consumeState(try self.processor().consumeResolved(input, output));
                } else unreachable,
                .each_safe => if (comptime resolve.Input == op.match.Input) {
                    if (resolve.eval(item.value)) |value| {
                        try self.appendItem(skip, i, value, item.used, true);
                        return null;
                    }
                } else unreachable,
                .each_fail => if (comptime resolve.Input == op.match.Input) {
                    const value = resolve.eval(item.value) orelse {
                        @branchHint(.unlikely);
                        self.scratch.deinit(self.allocator);
                        return .fail;
                    };
                    try self.appendItem(skip, i, value, item.used, true);
                    return null;
                } else unreachable,
                else => {},
            };

            try self.appendItem(skip, i, item.value, item.used, is_filtered);
            return null;
        }

        fn resolveLast(
            self: *Self,
            skip: behavior.Skip(),
            i: usize,
            item: EvalState(op.match.Input),
            comptime is_filtered: bool,
        ) !Evaluate(op) {
            if (comptime op.resolve) |resolve| behave: switch (comptime resolve.behavior) {
                .partial_defer => |min| if (i >= min) continue :behave .partial else unreachable,
                .partial => if (comptime resolve.Input == []const op.match.Input) {
                    try self.appendItem(skip, i, item.value, item.used, is_filtered);

                    const input = self.view(skip);
                    const output = resolve.eval(input) orelse {
                        @branchHint(.unlikely);
                        self.scratch.deinit(self.allocator);
                        return .fail;
                    };
                    return self.consumeState(try self.processor().consumeResolved(input, output));
                } else unreachable,
                .each_safe => if (comptime resolve.Input == op.match.Input) {
                    if (resolve.eval(item.value)) |value| {
                        try self.appendItem(skip, i, value, item.used, true);
                    } else {
                        try self.appendItem(skip, i, item.value, item.used, is_filtered);
                    }
                    return self.consumeState(try self.processor().consumeInput(self.view(skip)));
                } else unreachable,
                .each_fail => if (comptime resolve.Input == op.match.Input) {
                    const value = resolve.eval(item.value) orelse {
                        @branchHint(.unlikely);
                        self.scratch.deinit(self.allocator);
                        return .fail;
                    };
                    try self.appendItem(skip, i, value, item.used, true);
                    return self.consumeState(try self.processor().consumeInput(self.view(skip)));
                } else unreachable,
                else => if (comptime resolve.Input == []const op.match.Input) {
                    try self.appendItem(skip, i, item.value, item.used, is_filtered);
                    return self.consumeState(try self.processor().consume(self.view(skip), resolve));
                } else unreachable,
            };

            try self.appendItem(skip, i, item.value, item.used, is_filtered);
            return self.consumeState(try self.processor().consumeInput(self.view(skip)));
        }

        fn resolveExclude(self: *Self, skip: behavior.Skip()) !Evaluate(op) {
            if (op.resolve) |resolve| switch (resolve.behavior) {
                .each_safe, .each_fail => {},
                .safe, .fail => if (comptime resolve.Input == []const op.match.Input) {
                    const state = try self.processor().consume(self.view(skip), resolve);
                    return self.consumeState(state);
                } else unreachable,
                .partial, .partial_defer => unreachable, // Partial should have resolved by the previous iteration.
            };

            return self.consumeState(try self.processor().consumeInput(self.view(skip)));
        }

        fn appendItem(
            self: *Self,
            skip: behavior.Skip(),
            i: usize,
            value: op.match.Input,
            used: usize,
            comptime did_modify: bool,
        ) !void {
            if (did_modify and !(behavior.canTake() or self.hasScratch())) {
                @branchHint(.unlikely);
                std.debug.assert(i == self.used);
                try self.scratch.appendSlice(self.allocator, 0, self.provider.viewSlice(skip, i));
                self.active_scratch = true;
            }

            if (did_modify or behavior.canTake() or self.hasScratch()) try self.scratch.appendItem(self.allocator, i, value);
            if (behavior.canTake()) self.provider.drop(used);
            self.used += used;
        }

        fn consumeState(self: *Self, state: Process.State) !Evaluate(op) {
            const out_ptr = @typeInfo(op.Output()) == .pointer;
            switch (state) {
                .owned => |output| if (out_ptr and !self.hasScratch()) {
                    return .{ .ok = .fromOwned(output, self.padding + self.used) };
                } else unreachable,
                .view => |output| if (!out_ptr or behavior.allocate() == .avoid) {
                    return .{ .ok = .fromView(output, self.padding + self.used) };
                } else unreachable,
                .discard => return .discard,
                .fail => return .fail,
            }
        }

        fn processOwnership(ctx: *const anyopaque) ProcessOwnership {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            return if (self.hasScratch()) .scratch else .view;
        }

        fn processDiscard(ctx: *const anyopaque) void {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            self.provider.drop(self.padding + self.used);
        }

        fn processConsume(ctx: *anyopaque, output: *anyopaque) !void {
            if (comptime !use_scratch) unreachable;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const out: *[]const op.match.Input = @ptrCast(@alignCast(output));
            const slice = try self.scratch.consume(self.allocator);
            out.* = slice;
            self.active_scratch = false;
        }

        fn processDeinit(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.scratch.deinit(self.allocator);
            if (comptime use_scratch) self.active_scratch = false;
        }
    };
}

const ProcessOverlap = enum { none, partial, full };
const ProcessOwnership = enum { view, scratch, owned };
const ProcessBehavior = enum { standard, discard, clone };

const ProcessVTable = struct {
    deinit: fn (ctx: *anyopaque) void,
    discard: fn (ctx: *const anyopaque) void,
    ownership: fn (ctx: *const anyopaque) ProcessOwnership,
    consume: fn (ctx: *anyopaque, value: *anyopaque) anyerror!void = struct {
        fn f(_: *anyopaque, _: *anyopaque) !void {
            unreachable;
        }
    }.f,
};

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

        pub fn consume(self: Self, input: In, comptime resolver: ?combine.Resolver) !State {
            if (comptime resolver) |r| {
                if (r.eval(input)) |out| {
                    return self.consumeResolved(input, out);
                } else switch (r.behavior) {
                    .safe => return self.consumeInput(input),
                    .fail => {
                        @branchHint(.unlikely);
                        vtable.deinit(self.ctx);
                        return .fail;
                    },
                    else => unreachable,
                }
            } else {
                return self.consumeInput(input);
            }
        }

        pub fn consumeInput(self: Self, input: In) !State {
            std.debug.assert(In == Out);
            if (comptime behavior == .discard) {
                return self.discardInput();
            } else {
                return switch (vtable.ownership(self.ctx)) {
                    .view => if (behavior == .clone) self.cloneOutput(input) else .{ .view = input },
                    .scratch => .{ .owned = try self.consumeScratch() },
                    .owned => .{ .owned = input },
                };
            }
        }

        pub fn consumeResolved(self: Self, input: In, output: Out) !State {
            if (comptime behavior == .discard) {
                return self.discardInput();
            } else switch (valuesOverlap(input, output)) {
                .full => switch (vtable.ownership(self.ctx)) {
                    .view => return .{ .view = output },
                    .scratch => if (comptime can_overlap) {
                        return .{ .owned = @ptrCast(@alignCast(try self.consumeScratch())) };
                    } else unreachable,
                    .owned => {},
                },
                .none => if (behavior != .clone and vtable.ownership(self.ctx) == .view) return .{ .view = output },
                .partial => {},
            }

            defer vtable.deinit(self.ctx);
            return try self.cloneOutput(output);
        }

        fn discardInput(self: Self) State {
            vtable.deinit(self.ctx);
            vtable.discard(self.ctx);
            return .discard;
        }

        fn consumeScratch(self: Self) !In {
            var value: In = undefined;
            try vtable.consume(self.ctx, @ptrCast(&value));
            return value;
        }

        fn cloneOutput(self: Self, output: Out) !State {
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
        fn valuesOverlap(input: In, output: Out) ProcessOverlap {
            if (comptime !can_overlap) return .none;

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
            if (comptime filter) |f| blk: {
                comptime f.operator.validate(In, Out);
                switch (try Evaluate(f.operator).at(allocator, self.source, comptime behavior.asView(), i)) {
                    .ok => |state| switch (comptime f.behavior) {
                        .unless => return .fail,
                        else => return .{ .filtered = state },
                    },
                    .fail => switch (comptime f.behavior) {
                        .unless => break :blk,
                        .fail, .validate => return .fail,
                        .fallback, .override => {
                            try self.reserveItem(i);
                            return .{ .standard = .fromView(self.viewItem(i), 1) };
                        },
                    },
                    .discard => unreachable,
                }
            }

            try self.reserveItem(i);
            return .{ .standard = .fromView(self.viewItem(i), 1) };
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

test "Evaluate: match single" {
    var reader = TestingReader{ .buffer = "abc" };
    try TestingEvaluator(BuildOp.matchSingle(.ok)).expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.fail)).expectFail().evaluate(&reader, .{ .view = 1 });

    // Propogate reader failure
    reader.reset(.{ .fail = .{ .cursor = 0 } });
    try TestingEvaluator(BuildOp.matchSingle(.ok)).expectReaderError().evaluate(&reader, .{ .view = 1 });
}

test "Evaluate: match sequence" {
    var reader = TestingReader{ .buffer = "abcd" };
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.invalid, .{ .index = 2 }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Propogate reader failure
    reader.reset(.{ .fail = .{ .cursor = 0 } });
    try TestingEvaluator(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
        .expectReaderError().evaluate(&reader, .{ .view = 1 });
}

test "Evaluate: resolve" {
    var reader = TestingReader{ .buffer = "abcd" };

    //
    // Single
    //

    // Safe
    try TestingEvaluator(BuildOp.matchSingle(.ok).resolve(.safe, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).resolve(.safe, .fail))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });

    // Fail
    try TestingEvaluator(BuildOp.matchSingle(.ok).resolve(.fail, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).resolve(.fail, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).resolve(.fail, .fail))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    //
    // Sequence
    //

    // Safe
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.safe, .{ .constant_slice = "xx" }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.safe, .fail))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });

    // Fail
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.fail, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.fail, .{ .constant_char = 'x' }))
        .expectSuccess('x', 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.fail, .fail))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Partial
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.partial, .passthrough))
        .expectSuccess("b", 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.partial, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.partial, .fail))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Partial Defer
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.{ .partial_defer = 1 }, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.{ .partial_defer = 1 }, .{ .constant_char = 'x' }))
        .expectSuccess('x', 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.{ .partial_defer = 1 }, .fail))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Each Safe
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.each_safe, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.each_safe, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.each_safe, .fail))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });

    // Each Fail
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.each_fail, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.each_fail, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.each_fail, .fail))
        .expectFail().evaluate(&reader, .{ .view = 1 });
}

test "Evaluate: take single" {
    var reader = TestingReader{ .buffer = "ab" };
    try TestingEvaluator(BuildOp.matchSingle(.fail)).expectFail().evaluate(&reader, .take);
    try TestingEvaluator(BuildOp.matchSingle(.ok)).expectSuccess('a', 1).evaluate(&reader, .take);
    try TestingEvaluator(BuildOp.matchSingle(.ok)).expectSuccess('b', 1).evaluate(&reader, .take);
    try TestingEvaluator(BuildOp.matchSingle(.ok)).expectReaderError().evaluate(&reader, .take);
}

test "Evaluate: take sequence" {
    var reader = TestingReader{};
    try TestingEvaluator(BuildOp.matchSequence(.invalid, .{ .index = 1 }))
        .expectFail().evaluate(&reader, .take);
    try reader.expectCursor(1); // Takes the first char, then the second fails

    reader.reset(.{ .buffer = "abcde" });
    try TestingEvaluator(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
        .expectSuccess("ab", 2).evaluate(&reader, .take);
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess("cd", 2).evaluate(&reader, .take);
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectReaderError().evaluate(&reader, .take);
    try reader.expectCursor(5); // Takes the first char, then the second fails
}

test "Evaluate: clone" {
    var reader = TestingReader{};
    try TestingEvaluator(BuildOp.matchSequence(.invalid, .{ .index = 1 }))
        .expectFail().evaluate(&reader, .clone);
    try reader.expectCursor(1); // Takes the first char, then the second fails

    reader.reset(.{ .buffer = "abcde" });
    try TestingEvaluator(BuildOp.matchSequence(.done_exclude, .{ .index = 2 }))
        .expectSuccess("ab", 2).evaluate(&reader, .clone);
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess("cd", 2).evaluate(&reader, .clone);
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectReaderError().evaluate(&reader, .clone);
    try reader.expectCursor(5); // Takes the first char, then the second fails
}

test "Evaluate: drop" {
    var reader = TestingReader{};

    // Unresolved

    try TestingEvaluator(BuildOp.matchSingle(.ok)).expectSuccess(undefined, 1)
        .evaluate(&reader, .drop);
    try reader.expectCursor(1);

    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }))
        .expectSuccess(undefined, 2).evaluate(&reader, .drop);
    try reader.expectCursor(3);

    // Resolved

    try TestingEvaluator(BuildOp.matchSingle(.ok).resolve(.fail, .passthrough)).expectSuccess(undefined, 1)
        .evaluate(&reader, .drop);
    try reader.expectCursor(4);

    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).resolve(.fail, .{ .constant_char = 'x' }))
        .expectSuccess(undefined, 2).evaluate(&reader, .drop);
    try reader.expectCursor(6);
}

test "Evaluate: filter single" {
    var reader = TestingReader{ .buffer = "abc" };

    // Fail
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.fail, .ok, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.fail, .ok, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.fail, .fail, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Fallback
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.fallback, .ok, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.fallback, .ok, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.fallback, .fail, .{ .constant_char = 'x' }))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });

    // Override
    try TestingEvaluator(BuildOp.matchSingle(.{ .fail_value = 'b' }).filterSingle(.override, .ok, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.{ .fail_value = 'x' }).filterSingle(.override, .ok, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.{ .fail_value = 'x' }).filterSingle(.override, .fail, .{ .constant_char = 'x' }))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.{ .fail_value = 'b' }).filterSingle(.override, .fail, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Validate (same as fail for single matchers)
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.validate, .ok, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.validate, .ok, .{ .constant_char = 'x' }))
        .expectSuccess('x', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.validate, .fail, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Unless
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.unless, .fail, .{ .constant_char = 'x' }))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.unless, .fail, .passthrough))
        .expectSuccess('b', 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSingle(.ok).filterSingle(.unless, .ok, .passthrough))
        .expectFail().evaluate(&reader, .{ .view = 1 });
}

test "Evaluate: filter sequence" {
    var reader = TestingReader{ .buffer = "abcd" };

    // Fail
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fail, .ok, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fail, .ok, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fail, .fail, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Fallback
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fallback, .ok, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fallback, .ok, .{ .constant_char = 'x' }))
        .expectSuccess("xx", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).filterSingle(.fallback, .fail, .{ .constant_char = 'x' }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });

    // Override
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .value = 'c' }).filterSingle(.override, .{ .fail_value = 'c' }, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .value = 'c' }).filterSingle(.override, .{ .fail_value = 'c' }, .{ .constant_char = 'x' }))
        .expectSuccess("xc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.invalid, .{ .value = 'c' }).filterSingle(.override, .{ .fail_value = 'c' }, .{ .constant_char = 'x' }))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Validate
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .value = 'd' }).filterSingle(.validate, .{ .fail_value = 'c' }, .{ .constant_char = 'x' }))
        .expectSuccess("x", 1).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .value = 'd' }).filterSingle(.validate, .{ .fail_value = 'd' }, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.invalid, .{ .value = 'b' }).filterSingle(.validate, .{ .fail_value = 'c' }, .passthrough))
        .expectFail().evaluate(&reader, .{ .view = 1 });

    // Unless
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .value = 'd' }).filterSingle(.unless, .{ .fail_unless = 'd' }, .{ .constant_char = 'x' }))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .value = 'd' }).filterSingle(.unless, .{ .fail_unless = 'd' }, .passthrough))
        .expectSuccess("bc", 2).evaluate(&reader, .{ .view = 1 });
    try TestingEvaluator(BuildOp.matchSequence(.invalid, .{ .value = 'b' }).filterSingle(.unless, .{ .fail_unless = 'c' }, .passthrough))
        .expectFail().evaluate(&reader, .{ .view = 1 });
}

test "Evaluate: align single" {
    var reader = TestingReader{ .buffer = "abcd" };

    try TestingEvaluator(BuildOp.matchSingle(.ok).alignment(2))
        .expectSuccess('c', 2).evaluate(&reader, .{ .view = 1 });

    reader.drop(1);
    try TestingEvaluator(BuildOp.matchSingle(.ok).alignment(2))
        .expectSuccess('c', 2).evaluate(&reader, .take);
}

test "Evaluate: align sequence" {
    var reader = TestingReader{ .buffer = "abcd" };

    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).alignment(2))
        .expectSuccess("cd", 3).evaluate(&reader, .{ .view = 1 });

    reader.drop(1);
    try TestingEvaluator(BuildOp.matchSequence(.done_include, .{ .index = 1 }).alignment(2))
        .expectSuccess("cd", 3).evaluate(&reader, .take);
}

fn TestingEvaluator(comptime op: BuildOp) type {
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
