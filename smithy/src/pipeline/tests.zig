const std = @import("std");
const testing = std.testing;
const tsk = @import("task.zig");
const Task = tsk.Task;
const Delegate = tsk.Delegate;
const AbstractTask = @import("task_abstract.zig").AbstractTask;

pub const Service = struct { value: usize };

//
// Tasks
//

pub const NoOp = Task.Define("NoOp", noOpFn, .{});
pub fn noOpFn(_: *const Delegate) void {}

pub var did_call: bool = false;
pub const Call = Task.Define("Call", callFn, .{});
pub fn callFn(_: *const Delegate) void {
    did_call = true;
}

pub const Crash = Task.Define("Crash", crashFn, .{});
pub fn crashFn(_: *const Delegate) error{Fail}!void {
    return error.Fail;
}

pub const Failable = Task.Define("Failable", failableFn, .{});
pub fn failableFn(_: *const Delegate, fail: bool) error{Fail}!void {
    if (fail) return error.Fail;
}

pub const Multiply = Task.Define("Multiply", multiplyFn, .{});
pub fn multiplyFn(_: *const Delegate, a: usize, b: usize) usize {
    return a * b;
}

pub const InjectMultiply = Task.Define("InjectMultiply", injectMultiplyFn, .{
    .injects = &.{Service},
});
pub fn injectMultiplyFn(_: *const Delegate, service: *Service, n: usize) usize {
    return n * service.value;
}

pub const OptInjectMultiply = Task.Define("OptInjectMultiply", optInjectMultiplyFn, .{
    .injects = &.{Service},
});
pub fn optInjectMultiplyFn(_: *const Delegate, service: ?*Service, n: usize) usize {
    const m: usize = if (service) |t| t.value else 1;
    return n * m;
}

pub const MultiplyScope = Task.Define("MultiplyScope", multiplyScopeFn, .{});
pub fn multiplyScopeFn(self: *const Delegate, n: usize) !void {
    const m = self.readValue(usize, .num) orelse return error.MissingValue;
    try self.writeValue(usize, .num, m * n);
}

pub const ExponentScope = Task.Define("ExponentScope", exponentScopeFn, .{});
pub fn exponentScopeFn(self: *const Delegate, n: usize) !void {
    try self.schedule(MultiplyScope, .{n});
    const m = self.readValue(usize, .num) orelse return error.MissingValue;
    try self.writeValue(usize, .num, m * n);
}

pub const MultiplySubScope = Task.Define("MultiplySubScope", multiplySubScopeFn, .{});
pub fn multiplySubScopeFn(self: *const Delegate, n: usize) !void {
    const m = self.readValue(usize, .mult) orelse return error.MissingValue;
    try self.defineValue(usize, .num, n);
    try self.evaluate(MultiplyScope, .{m});
    const prod = self.readValue(usize, .num) orelse return error.MissingValue;
    try self.writeValue(usize, .mult, prod);
}

//
// Abstract
//

pub const AbstractCall = AbstractTask.Define("Call", callWrapper, .{
    .varyings = &.{usize},
});
pub fn callWrapper(_: *const Delegate, n: usize, task: *const fn (struct { usize }) usize) usize {
    did_call = true;
    return task(.{n});
}

pub const AbstractChain = AbstractTask.Define("Chain", chainWrapper, .{
    .varyings = &.{usize},
});
pub fn chainWrapper(_: *const Delegate, n: usize, task: *const fn (struct { usize }) anyerror!usize) !usize {
    return task(.{n});
}

pub const AbstractCallAdd = AbstractCall.Abstract("Call & Add", addMidWrapper, .{
    .varyings = &.{usize},
});
pub fn addMidWrapper(_: *const Delegate, n: usize, task: *const fn (struct { usize }) usize) usize {
    return task(.{n + 1});
}

//
// Hooks
//

pub const NoOpHook = Task.Hook("NoOp Hook", void, &.{bool});

//
// Callbacks
//

pub fn noopCb(_: *const anyopaque) anyerror!void {}

pub fn failableCb(_: *const anyopaque, output: error{Fail}!void) anyerror!void {
    try output;
}

pub fn multiplyCb(ctx: *const anyopaque, output: usize) anyerror!void {
    const cast: *const usize = @alignCast(@ptrCast(ctx));
    try testing.expectEqual(cast.*, output);
}
