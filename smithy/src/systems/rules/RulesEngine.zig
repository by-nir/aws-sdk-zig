const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const rls = @import("model.zig");
const lib = @import("library.zig");
const Generator = @import("Generator.zig");
const ContainerBuild = @import("../../codegen/zig.zig").ContainerBuild;

const Self = @This();

fn Map(comptime T: type) type {
    return std.AutoHashMapUnmanaged(T.Id, T);
}

built_ins: Map(lib.BuiltIn),
functions: Map(lib.Function),

pub fn init(allocator: Allocator, built_ins: lib.BuiltInsRegistry, functions: lib.FunctionsRegistry) !Self {
    var map_bi = try initMap(lib.BuiltIn, allocator, lib.std_builtins, built_ins);
    const map_fn = initMap(lib.Function, allocator, lib.std_functions, functions) catch |err| {
        map_bi.deinit(allocator);
        return err;
    };

    return .{
        .built_ins = map_bi,
        .functions = map_fn,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.built_ins.deinit(allocator);
    self.functions.deinit(allocator);
}

fn initMap(comptime T: type, allocator: Allocator, reg1: lib.Registry(T), reg2: lib.Registry(T)) !Map(T) {
    var map = Map(T){};
    try map.ensureTotalCapacity(allocator, @intCast(reg1.len + reg2.len));
    for (reg1) |kv| map.putAssumeCapacity(kv[0], kv[1]);
    for (reg2) |kv| map.putAssumeCapacity(kv[0], kv[1]);
    return map;
}

pub fn getBuiltIn(self: Self, id: lib.BuiltIn.Id) !lib.BuiltIn {
    return self.built_ins.get(id) orelse error.RulesBuiltInUnknown;
}

pub fn getFunc(self: Self, id: lib.Function.Id) !lib.Function {
    return self.functions.get(id) orelse error.RulesFuncUnknown;
}

pub fn generateConfigFields(self: Self, arena: Allocator, bld: *ContainerBuild, params: Generator.ParamsList) !void {
    var gen = try Generator.init(arena, self, params);
    try gen.generateParametersFields(bld);
}

pub fn generateResolver(
    self: Self,
    arena: Allocator,
    bld: *ContainerBuild,
    func_name: []const u8,
    config_type: []const u8,
    rule_set: *const rls.RuleSet,
) !void {
    var gen = try Generator.init(arena, self, rule_set.parameters);
    try gen.generateResolver(bld, func_name, config_type, rule_set.rules);
}
