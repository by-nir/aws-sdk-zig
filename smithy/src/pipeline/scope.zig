const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const scd = @import("schedule.zig");
const Task = @import("task.zig").Task;
const util = @import("utils.zig");
const ComptimeTag = util.ComptimeTag;
const Reference = util.Reference;

pub const NOOP_DELEGATE = Delegate{
    .children = .{},
    .scope = undefined,
    .scheduler = undefined,
};

pub const Delegate = struct {
    scope: *Scope,
    scheduler: *scd.Schedule,
    children: scd.ScheduleQueue,
    branchScope: ?*const fn (Delegate: *const Delegate) anyerror!void = null,

    pub fn invokeSync(self: *const Delegate, comptime task: Task, input: task.In(false)) !task.Out(.strip) {
        return self.scheduler.invokeSync(self, task, input);
    }

    pub fn scheduleAsync(self: *const Delegate, comptime task: Task, input: task.In(false)) !void {
        try self.scheduler.appendAsync(self, task, input);
    }

    pub fn scheduleCallback(
        self: *const Delegate,
        comptime task: Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: Task.Callback(task),
    ) !void {
        try self.scheduler.appendCallback(self, task, input, context, callback);
    }

    pub fn provide(
        self: *const Delegate,
        value: anytype,
        comptime cleanup: ?*const fn (ctx: Reference(@TypeOf(value)), allocator: Allocator) void,
    ) !Reference(@TypeOf(value)) {
        if (self.branchScope) |branch| try branch(self);
        return self.scope.provideService(value, cleanup);
    }

    pub fn defineValue(self: *const Delegate, comptime T: type, comptime tag: anytype, value: T) !void {
        if (self.branchScope) |branch| try branch(self);
        try self.scope.defineValue(T, tag, value);
    }

    pub fn writeValue(self: Delegate, comptime T: type, comptime tag: anytype, value: T) !void {
        try self.scope.writeValue(T, tag, value);
    }

    pub fn readValue(self: Delegate, comptime T: type, comptime tag: anytype) util.Optional(T) {
        return self.scope.readValue(T, tag);
    }

    pub fn hasValue(self: Delegate, comptime tag: anytype) bool {
        return self.scope.hasValue(tag);
    }
};

pub const Scope = struct {
    arena: std.heap.ArenaAllocator,
    parent: ?*Scope = null,
    services: std.AutoArrayHashMapUnmanaged(ComptimeTag, Service) = .{},
    blackboard: std.AutoArrayHashMapUnmanaged(ComptimeTag, *anyopaque) = .{},

    const Service = struct {
        value: *anyopaque,
        cleanup: ?*const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn init(child_allocator: Allocator, parent: ?*Scope) Scope {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .parent = parent,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.cleanupServices();
        self.arena.deinit();
    }

    pub fn reset(self: *Scope) void {
        self.cleanupServices();
        self.blackboard = .{};
        self.services = .{};
        self.parent = null;
        _ = self.arena.reset(.retain_capacity);
    }

    fn cleanupServices(self: *Scope) void {
        const arena_alloc = self.arena.allocator();
        for (self.services.values()) |service| {
            const cleanup = service.cleanup orelse continue;
            cleanup(service.value, arena_alloc);
        }
    }

    pub fn alloc(self: *Scope) Allocator {
        return self.arena.allocator();
    }

    pub fn provideService(
        self: *Scope,
        value: anytype,
        comptime cleanup: ?*const fn (ctx: Reference(@TypeOf(value)), allocator: Allocator) void,
    ) !Reference(@TypeOf(value)) {
        const T = @TypeOf(value);
        const meta = @typeInfo(T);
        const id = ComptimeTag.of(Reference(T));
        if (self.services.contains(id)) return error.ServiceAlreadyProvidedByScope;

        const arena_alloc = self.arena.allocator();
        const service: Reference(T) = switch (meta) {
            .Struct => blk: {
                const dupe = try arena_alloc.create(T);
                dupe.* = value;
                break :blk dupe;
            },
            .Pointer => |t| blk: {
                if (@typeInfo(t.child) != .Struct or t.size != .One)
                    @compileError("Only a struct may be provided as a service; trying to provide " ++ @typeName(T))
                else if (t.is_const)
                    @compileError("A service must be mutable; trying to provide " ++ @typeName(T))
                else
                    break :blk value;
            },
            else => @compileError("Only a struct may be provided as a service; trying to provide a " ++ @typeName(T)),
        };
        errdefer if (meta == .Struct) arena_alloc.destroy(service);

        try self.services.put(arena_alloc, id, .{
            .value = service,
            .cleanup = if (cleanup) |f| struct {
                fn deinit(ctx: *anyopaque, allocator: Allocator) void {
                    f(@alignCast(@ptrCast(ctx)), allocator);
                }
            }.deinit else null,
        });
        return service;
    }

    pub fn getService(self: *const Scope, comptime T: type) ?Reference(T) {
        const tag = ComptimeTag.of(Reference(T));
        if (self.services.get(tag)) |t|
            return @alignCast(@ptrCast(t.value))
        else if (self.parent) |p|
            return p.getService(T)
        else
            return null;
    }

    pub fn defineValue(self: *Scope, comptime T: type, comptime tag: anytype, value: T) !void {
        const id = valueId(tag);
        const meta = @typeInfo(T);
        if (self.blackboard.contains(id)) {
            return error.ValueAlreadyDefinedInScope;
        } else if (meta != .Pointer or meta.Pointer.size == .Slice) {
            const arena_alloc = self.arena.allocator();
            const ref = try arena_alloc.create(T);
            ref.* = value;
            errdefer arena_alloc.destroy(ref);
            try self.blackboard.put(arena_alloc, id, @ptrCast(ref));
        } else {
            try self.blackboard.put(self.arena.allocator(), id, @constCast(value));
        }
    }

    pub fn writeValue(self: *Scope, comptime T: type, comptime tag: anytype, value: T) !void {
        const id = valueId(tag);
        if (self.blackboard.getPtr(id)) |t| {
            const meta = @typeInfo(T);
            const is_val = meta != .Pointer;
            const Ref = if (is_val) Reference(T) else *Reference(T);
            const ref: Ref = if (is_val or meta.Pointer.size == .Slice)
                @alignCast(@ptrCast(t.*))
            else
                @alignCast(@ptrCast(t));
            ref.* = value;
        } else if (self.parent) |p| {
            return p.writeValue(T, tag, value);
        } else {
            return error.UndefinedValue;
        }
    }

    pub fn readValue(self: *const Scope, comptime T: type, comptime tag: anytype) util.Optional(T) {
        const id = valueId(tag);
        if (self.blackboard.get(id)) |t| {
            const meta = @typeInfo(T);
            const is_ptr = meta == .Pointer;
            const is_slice = is_ptr and meta.Pointer.size == .Slice;
            const Ref = if (!is_ptr or !is_slice) Reference(T) else *Reference(T);
            const ref: Ref = @alignCast(@ptrCast(t));
            return if (!is_ptr or is_slice) ref.* else ref;
        } else if (self.parent) |p| {
            return p.readValue(T, tag);
        } else {
            return null;
        }
    }

    pub fn hasValue(self: *const Scope, comptime tag: anytype) bool {
        const id = valueId(tag);
        return self.blackboard.contains(id) or
            if (self.parent) |p| p.hasValue(tag) else false;
    }

    fn valueId(comptime tag: anytype) ComptimeTag {
        switch (@typeInfo(@TypeOf(tag))) {
            .Enum, .EnumLiteral => {},
            else => @compileError("A scope value tag must by an enum or an enum literal."),
        }
        return ComptimeTag.of(tag);
    }
};

test "Scope: services" {
    const Dummy = struct {
        value: usize,

        pub var last_deinit_value: usize = 0;

        pub fn deinit(self: *@This(), _: Allocator) void {
            last_deinit_value = self.value;
        }
    };

    var scope = Scope.init(test_alloc, null);
    defer scope.deinit();

    // Provide value service
    const dummy = try scope.provideService(Dummy{ .value = 101 }, null);

    // Prevent overriding services in the same scope
    try testing.expectError(
        error.ServiceAlreadyProvidedByScope,
        scope.provideService(Dummy{ .value = 999 }, null),
    );

    // Value type service results in a mutable reference
    {
        const get = scope.getService(Dummy);
        try testing.expectEqualDeep(dummy, get);

        get.?.value = 102;
        try testing.expectEqual(102, dummy.value);
    }

    //
    // Children
    //

    {
        var child = Scope.init(test_alloc, &scope);
        defer child.deinit();

        // Get parent service
        try testing.expectEqualDeep(dummy, child.getService(Dummy));

        // Provide with cleanup
        const override = try child.provideService(Dummy{ .value = 201 }, Dummy.deinit);
        try testing.expectEqual(201, override.value);

        // Overrides parent services
        try testing.expectEqualDeep(override, child.getService(Dummy));
    }

    // Did call cleanup?
    try testing.expectEqual(201, Dummy.last_deinit_value);

    //
    // Reset
    //

    scope.reset();
    try testing.expectEqual(null, scope.getService(Dummy));

    //
    // Reference type
    //

    var ref_dummy = Dummy{ .value = 301 };
    try testing.expectEqual(
        &ref_dummy,
        try scope.provideService(&ref_dummy, Dummy.deinit),
    );
    try testing.expectEqual(&ref_dummy, scope.getService(Dummy));
    scope.reset();
}

test "Scope: blackboard" {
    var scope = Scope.init(test_alloc, null);
    defer scope.deinit();

    // Has value?
    try testing.expectEqual(false, scope.hasValue(.val));

    // Prevent writing to an undefined value
    try testing.expectError(
        error.UndefinedValue,
        scope.writeValue(usize, .val, 102),
    );

    //
    // Value type
    //

    // Define
    try scope.defineValue(usize, .val, 101);
    try testing.expectEqual(true, scope.hasValue(.val));

    // Read
    try testing.expectEqualDeep(101, scope.readValue(usize, .val));

    // Write
    try scope.writeValue(usize, .val, 102);
    try testing.expectEqualDeep(102, scope.readValue(usize, .val));

    // Prevent override definition
    try testing.expectError(
        error.ValueAlreadyDefinedInScope,
        scope.defineValue(usize, .val, 101),
    );

    //
    // Children
    //

    {
        var child = Scope.init(test_alloc, &scope);
        defer child.deinit();

        // Child has
        try testing.expectEqual(true, child.hasValue(.val));

        // Child read
        try testing.expectEqualDeep(102, child.readValue(usize, .val));

        // Child write
        try child.writeValue(usize, .val, 103);
        try testing.expectEqualDeep(103, scope.readValue(usize, .val));

        // Child override
        try child.defineValue(usize, .val, 201);
        try testing.expectEqualDeep(201, child.readValue(usize, .val));
    }

    //
    // Rest
    //

    scope.reset();
    try testing.expectEqual(false, scope.hasValue(.val));
    try testing.expectEqual(null, scope.readValue(bool, .val));

    //
    // Pointer type
    //

    // Define
    try scope.defineValue(*const usize, .ptr, &201);
    try testing.expectEqual(true, scope.hasValue(.ptr));

    // Read
    try testing.expectEqualDeep(&@as(usize, 201), scope.readValue(*const usize, .ptr));

    // Write
    try scope.writeValue(*const usize, .ptr, &202);
    try testing.expectEqualDeep(&@as(usize, 202), scope.readValue(*const usize, .ptr));

    //
    // Slice type
    //

    // Define
    try scope.defineValue([]const usize, .slc, &.{ 301, 401 });
    try testing.expectEqual(true, scope.hasValue(.slc));

    // Read
    try testing.expectEqualDeep(&[_]usize{ 301, 401 }, scope.readValue([]const usize, .slc));

    // Write
    try scope.writeValue([]const usize, .slc, &.{ 302, 402 });
    try testing.expectEqualDeep(&[_]usize{ 302, 402 }, scope.readValue([]const usize, .slc));
}
