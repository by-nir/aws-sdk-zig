const std = @import("std");
const testing = std.testing;
const tsk = @import("task.zig");
const Task = tsk.Task;
const Delegate = tsk.Delegate;

pub const Service = struct { value: usize };

//
// Tasks
//

pub const NoOp = Task.define("NoOp", noOpFn, .{});
pub fn noOpFn(_: *const Delegate) void {}

pub var did_call: bool = false;
pub const Call = Task.define("Call", callFn, .{});
pub fn callFn(_: *const Delegate) void {
    did_call = true;
}

pub const Crash = Task.define("Crash", crashFn, .{});
pub fn crashFn(_: *const Delegate) error{Fail}!void {
    return error.Fail;
}

pub const Failable = Task.define("Failable", failableFn, .{});
pub fn failableFn(_: *const Delegate, fail: bool) error{Fail}!void {
    if (fail) return error.Fail;
}

pub const Multiply = Task.define("Multiply", multiplyFn, .{});
pub fn multiplyFn(_: *const Delegate, a: usize, b: usize) usize {
    return a * b;
}

pub const InjectMultiply = Task.define("InjectMultiply", injectMultiplyFn, .{
    .inject = &.{Service},
});
pub fn injectMultiplyFn(_: *const Delegate, service: *Service, n: usize) usize {
    return n * service.value;
}

pub const OptInjectMultiply = Task.define("OptInjectMultiply", optInjectMultiplyFn, .{
    .inject = &.{Service},
});
pub fn optInjectMultiplyFn(_: *const Delegate, service: ?*Service, n: usize) usize {
    const m: usize = if (service) |t| t.value else 1;
    return n * m;
}

pub const MultiplyScope = Task.define("MultiplyScope", multiplyScopeFn, .{});
pub fn multiplyScopeFn(task: *const Delegate, n: usize) !void {
    const m = task.readValue(usize, .num) orelse return error.MissingValue;
    try task.writeValue(usize, .num, m * n);
}

pub const ExponentScope = Task.define("ExponentScope", exponentScopeFn, .{});
pub fn exponentScopeFn(task: *const Delegate, n: usize) !void {
    try task.schedule(MultiplyScope, .{n});
    const m = task.readValue(usize, .num) orelse return error.MissingValue;
    try task.writeValue(usize, .num, m * n);
}

pub const MultiplySubScope = Task.define("MultiplySubScope", multiplySubScopeFn, .{});
pub fn multiplySubScopeFn(task: *const Delegate, n: usize) !void {
    const m = task.readValue(usize, .mult) orelse return error.MissingValue;
    try task.defineValue(usize, .num, n);
    try task.evaluate(MultiplyScope, .{m});
    const prod = task.readValue(usize, .num) orelse return error.MissingValue;
    try task.writeValue(usize, .mult, prod);
}

//
// Hooks
//

pub const NoOpHook = Task.hook("NoOp Hook", &.{bool}, void);

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
