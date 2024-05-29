const std = @import("std");
const TypeMeta = std.builtin.Type;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

fn fnMeta(comptime T: type) TypeMeta.Fn {
    return switch (@typeInfo(T)) {
        .Fn => |f| f,
        .Pointer => |p| @typeInfo(p.child).Fn,
        else => unreachable,
    };
}

fn FnReturn(comptime T: type) type {
    const meta = fnMeta(T);
    return meta.return_type.?;
}

pub fn Closure(comptime Context: type, comptime Fn: type) type {
    var meta = fnMeta(Fn);
    if (Context == void) {
        return *const @Type(.{ .Fn = meta });
    } else {
        var params: [meta.params.len + 1]TypeMeta.Fn.Param = undefined;
        params[0] = .{
            .is_generic = false,
            .is_noalias = false,
            .type = Context,
        };
        @memcpy(params[1..], meta.params);

        meta.params = &params;
        return *const @Type(.{ .Fn = meta });
    }
}

test "Closure" {
    try testing.expectEqual(
        *const fn (bool) anyerror!u8,
        Closure(void, fn (_: bool) anyerror!u8),
    );
    try testing.expectEqual(
        *const fn (usize, bool) anyerror!u8,
        Closure(usize, fn (_: bool) anyerror!u8),
    );
}

pub fn callClosure(ctx: anytype, closure: anytype, args: anytype) FnReturn(@TypeOf(closure)) {
    const Context = @TypeOf(ctx);
    const Arga = @TypeOf(args);
    const args_meta = @typeInfo(Arga).Struct;
    if (!args_meta.is_tuple) {
        @compileError("Function callClosure expects `args` type of tuple.");
    } else {
        const a = if (Context == void) args else ClosureMergeArgs(Context, Arga)(ctx, args);
        return @call(.auto, closure, a);
    }
}

fn ClosureMergeArgs(
    comptime Context: type,
    comptime Args: type,
) fn (Context, Args) ClosureCtxArgs(Context, Args) {
    const CtxArgs = ClosureCtxArgs(Context, Args);
    const Static = struct {
        fn merge(_ctx: Context, _args: Args) CtxArgs {
            var combo: CtxArgs = undefined;
            combo[0] = _ctx;
            inline for (0.._args.len) |i| {
                combo[i + 1] = @field(_args, std.fmt.comptimePrint("{d}", .{i}));
            }
            return combo;
        }
    };
    return Static.merge;
}

fn ClosureCtxArgs(comptime Context: type, comptime Args: type) type {
    const origin = @typeInfo(Args).Struct.fields;
    var target: [origin.len + 1]TypeMeta.StructField = undefined;
    target[0] = .{
        .name = "0",
        .type = Context,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(Context),
    };
    for (origin, 1..) |field, i| {
        target[i] = field;
        target[i].name = std.fmt.comptimePrint("{d}", .{i});
    }
    return @Type(.{ .Struct = .{
        .layout = .auto,
        .fields = &target,
        .decls = &.{},
        .is_tuple = true,
    } });
}

test "callClosure" {
    const Test = struct {
        fn plain(add: u8) u8 {
            return 100 + add;
        }

        fn ctx(a: u8, b: u8) u8 {
            return a + b;
        }
    };

    try testing.expectEqual(108, callClosure({}, Test.plain, .{8}));
    try testing.expectEqual(108, callClosure(100, Test.ctx, .{8}));
}

pub fn Callback(comptime Ctx: type, comptime Val: type, comptime Rtrn: type) type {
    comptime var can_return_error = false;
    const ExpandReturn = switch (@typeInfo(Rtrn)) {
        .ErrorUnion => |t| blk: {
            can_return_error = true;
            break :blk anyerror!t.payload;
        },
        else => Rtrn,
    };
    return struct {
        const Self = @This();
        pub const Context = Ctx;
        pub const Value = Val;
        pub const Return = ExpandReturn;
        pub const Fn = *const fn (ctx: Context, value: Value) Return;

        ctx: Context,
        func: Fn,

        pub fn invoke(self: @This(), value: Value) Return {
            return self.func(self.ctx, value);
        }

        pub fn fail(self: @This(), err: anyerror) Return {
            if (can_return_error) {
                return err;
            } else if (@typeInfo(Value) == .ErrorUnion) {
                return self.invoke(err);
            } else {
                @panic("Unhandled callback error.");
            }
        }
    };
}

test "Callback" {
    const Cb = Callback(u8, u8, u8);
    const cb = Cb{
        .ctx = 100,
        .func = CallbackTest.cb,
    };
    try testing.expectEqual(108, cb.invoke(8));
}

pub fn callback(ctx: anytype, func: anytype) InferCallback(@TypeOf(func)) {
    return .{
        .ctx = ctx,
        .func = func,
    };
}

test "callback" {
    const cb = callback(100, CallbackTest.cb);
    try testing.expectEqual(108, cb.invoke(8));
}

pub fn InferCallback(comptime Fn: type) type {
    const meta = fnMeta(Fn);
    if (meta.params.len != 2) {
        @compileError("A callback function must have exactly 2 parameters: context and value.");
    } else if (meta.is_generic) {
        @compileError("A callback can’t be generic.");
    } else if (meta.is_var_args) {
        @compileError("A callback use variadic args.");
    }
    return Callback(
        meta.params[0].type.?,
        meta.params[1].type.?,
        meta.return_type.?,
    );
}

const CallbackTest = struct {
    fn cb(ctx: u8, arg: u8) u8 {
        return ctx + arg;
    }
};

/// A simple linked list for active stack scoped without heap allocations.
/// As long as all the relevant scopes are not dismissed the whole chain is accessible.
pub fn StackChain(comptime T: type) type {
    const is_optional = @typeInfo(T) == .Optional;
    const Value = if (is_optional) @typeInfo(T).Optional.child else T;

    return struct {
        const Self = @This();

        value: T = if (is_optional) null else undefined,
        len: usize = 1,
        prev: ?*const Self = null,

        pub fn start(value: Value) Self {
            return .{ .value = value };
        }

        pub fn append(self: *const Self, value: Value) Self {
            const no_value = is_optional and self.value == null;
            return .{
                .value = value,
                .len = if (no_value) self.len else self.len + 1,
                .prev = if (no_value) self.prev else self,
            };
        }

        pub fn count(self: Self) usize {
            return if (self.isEmpty()) 0 else self.len;
        }

        pub fn isEmpty(self: Self) bool {
            const has_items = !is_optional or self.value != null or self.prev != null;
            return !has_items;
        }

        pub fn unwrapIntro(self: *const Self, buffer: []Value) ![]const Value {
            if (self.isEmpty()) {
                return &.{};
            } else if (self.len > buffer.len) {
                return error.InsufficientBufferSize;
            }

            var i = self.len - 1;
            var it = self.iterateReversed();
            while (it.next()) |val| : (i -%= 1) {
                buffer[i] = val;
            }

            return buffer[0..self.len];
        }

        pub fn unwrapAlloc(self: *const Self, allocator: Allocator) ![]const Value {
            if (self.isEmpty()) return &.{};

            const buffer = try allocator.alloc(Value, self.len);
            errdefer allocator.free(buffer);

            var i = self.len - 1;
            var it = self.iterateReversed();
            while (it.next()) |val| : (i -%= 1) {
                buffer[i] = val;
            }

            return buffer;
        }

        /// Iterates the chain from last item to the first.
        pub fn iterateReversed(self: *const Self) Iterator {
            return Iterator{ .current = self };
        }

        pub const Iterator = struct {
            current: ?*const Self,

            pub fn next(it: *Iterator) if (is_optional) T else ?T {
                if (it.current == null) {
                    return null;
                } else if (is_optional and it.current.?.value == null) {
                    it.current = null;
                    return null;
                }

                defer it.current = it.current.?.prev;
                return it.current.?.value;
            }
        };
    };
}

test "StackChain: same scope linking" {
    const chain = StackChain([]const u8).start("foo").append("bar").append("baz");
    try testing.expectEqualStrings("baz", chain.value);
    try testing.expectEqualStrings("bar", chain.prev.?.value);
    try testing.expectEqualStrings("foo", chain.prev.?.prev.?.value);
}

test "StackChain: cross-scope behavior" {
    const Chain = StackChain([]const u8);
    const Scope = struct {
        var ptr_bar: usize = undefined;
        var ptr_foo: usize = undefined;

        fn extend(prev: Chain, append: []const u8) !Chain {
            const chain = prev.append("bar").append(append);
            ptr_bar = @intFromPtr(chain.prev.?);
            ptr_foo = @intFromPtr(chain.prev.?.prev.?);

            // Works while all relevant scope are still on the stack:
            try testing.expectEqualStrings("baz", chain.value);
            try testing.expectEqualStrings("bar", chain.prev.?.value);
            try testing.expectEqualStrings("foo", chain.prev.?.prev.?.value);

            return chain;
        }
    };

    const foo = Chain.start("foo");
    const chain = try Scope.extend(foo, "baz");

    // Fails when some of the scopes are dismissed:
    try testing.expectEqualStrings("baz", chain.value);
    try testing.expectEqual(Scope.ptr_bar, @intFromPtr(chain.prev.?));
    try testing.expect(Scope.ptr_foo != @intFromPtr(chain.prev.?.prev.?));
}

test "StackChain: optional append" {
    var chain = StackChain(?[]const u8){};
    try testing.expect(chain.isEmpty());

    chain = chain.append("foo").append("bar").append("baz");
    try testing.expectEqual(false, chain.isEmpty());
    try testing.expectEqualDeep("baz", chain.value);
    try testing.expectEqualDeep("bar", chain.prev.?.value);
    try testing.expectEqualDeep("foo", chain.prev.?.prev.?.value);
}

test "StackChain: optional override" {
    var chain = StackChain(?[]const u8).start("foo").append("REMOVE");
    chain.value = null;
    chain = chain.append("bar");
    try testing.expectEqualDeep("bar", chain.value);
    try testing.expectEqualDeep("foo", chain.prev.?.value);
    try testing.expectEqual(null, chain.prev.?.prev);
}

test "StackChain.unwrap" {
    const chain = StackChain([]const u8).start("foo").append("bar").append("baz");

    var buffer_small: [2][]const u8 = undefined;
    try testing.expectError(
        error.InsufficientBufferSize,
        chain.unwrapIntro(&buffer_small),
    );

    var buffer: [4][]const u8 = undefined;
    try testing.expectEqualDeep(
        &[_][]const u8{ "foo", "bar", "baz" },
        try chain.unwrapIntro(&buffer),
    );
}

test "StackChain.unwrap optional" {
    const chain = StackChain(?[]const u8).start("foo").append("bar").append("baz");

    var buffer_small: [2][]const u8 = undefined;
    try testing.expectError(
        error.InsufficientBufferSize,
        chain.unwrapIntro(&buffer_small),
    );

    var buffer: [4][]const u8 = undefined;
    try testing.expectEqualDeep(
        &[_][]const u8{ "foo", "bar", "baz" },
        try chain.unwrapIntro(&buffer),
    );
}

test "StackChain.unwrapAlloc" {
    const chain = StackChain([]const u8).start("foo").append("bar").append("baz");
    const items = try chain.unwrapAlloc(test_alloc);
    defer test_alloc.free(items);
    try testing.expectEqualDeep(&[_][]const u8{ "foo", "bar", "baz" }, items);
}

test "StackChain.unwrapAlloc optional" {
    const chain = StackChain(?[]const u8).start("foo").append("bar").append("baz");
    const items = try chain.unwrapAlloc(test_alloc);
    defer test_alloc.free(items);
    try testing.expectEqualDeep(&[_][]const u8{ "foo", "bar", "baz" }, items);
}

test "StackChain.iterateReversed" {
    const chain = StackChain([]const u8).start("foo").append("bar").append("baz");
    var it = chain.iterateReversed();
    try testing.expectEqualStrings("baz", it.next().?);
    try testing.expectEqualStrings("bar", it.next().?);
    try testing.expectEqualStrings("foo", it.next().?);
    try testing.expectEqual(null, it.next());
}
