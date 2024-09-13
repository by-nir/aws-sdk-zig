const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyType = mdl.SmithyType;
const SmithyMeta = mdl.SmithyMeta;
const SmithyTaggedValue = mdl.SmithyTaggedValue;
const Model = @import("../parse/Model.zig");
const TraitsProvider = @import("traits.zig").TraitsProvider;
const name_util = @import("../utils/names.zig");
const AuthId = @import("../traits/auth.zig").AuthId;
const error_trait_id = @import("../traits/refine.zig").Error.id;

const Self = @This();

arena: Allocator,
model_meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{},
model_shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},
model_names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{},
model_traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue) = .{},
model_mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{},
service_id: SmithyId = SmithyId.NULL,
service_errors: []const SmithyId = &.{},
service_operations: []const SmithyId = &.{},
service_data_shapes: []const SmithyId = &.{},
service_auth_schemes: []const AuthId = &.{},

pub fn consumeModel(arena: Allocator, model: *Model) !Self {
    var dupe_meta = try model.meta.clone(arena);
    errdefer dupe_meta.deinit(arena);

    var dupe_shapes = try model.shapes.clone(arena);
    errdefer dupe_shapes.deinit(arena);

    var dupe_names = try model.names.clone(arena);
    errdefer dupe_names.deinit(arena);

    var dupe_traits = try model.traits.clone(arena);
    errdefer dupe_traits.deinit(arena);

    var dupe_mixins = try model.mixins.clone(arena);
    errdefer dupe_mixins.deinit(arena);

    const sid = model.service_id;
    const errors: []const SmithyId = if (dupe_shapes.get(sid)) |t| t.service.errors else &.{};
    const operations, const shapes =
        try filterServiceShapes(model.allocator, arena, sid, &dupe_shapes, &dupe_traits);

    defer model.deinit();
    return .{
        .arena = arena,
        .model_meta = dupe_meta,
        .model_shapes = dupe_shapes,
        .model_names = dupe_names,
        .model_traits = dupe_traits,
        .model_mixins = dupe_mixins,
        .service_id = sid,
        .service_operations = operations,
        .service_data_shapes = shapes,
        .service_errors = errors,
    };
}

/// Flatten and sort the service’s shapes into two lists: operations and _named_ data shapes.
fn filterServiceShapes(
    gpa: Allocator,
    arena: Allocator,
    sid: SmithyId,
    shapes: *const std.AutoHashMapUnmanaged(SmithyId, SmithyType),
    traits: *const std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue),
) !struct { []const SmithyId, []const SmithyId } {
    var operations = std.ArrayList(SmithyId).init(arena);
    var data_shapes = std.ArrayList(SmithyId).init(arena);

    var visited: std.AutoHashMapUnmanaged(SmithyId, void) = .{};
    defer visited.deinit(gpa);

    var shape_queue: std.fifo.LinearFifo(SmithyId, .Dynamic) = .init(gpa);
    defer shape_queue.deinit();

    if (shapes.get(sid) != null)
        try shape_queue.writeItem(sid)
    else
        return .{ &.{}, &.{} };

    while (shape_queue.readItem()) |id| {
        if (visited.contains(id)) continue;
        try visited.put(gpa, id, {});

        switch (shapes.get(id).?) {
            .operation => |op| {
                try operations.append(id);
                if (op.input) |tid| try shape_queue.write(shapes.get(tid).?.structure);
                if (op.output) |tid| try shape_queue.write(shapes.get(tid).?.structure);
                try shape_queue.write(op.errors);
            },
            .resource => |rsrc| {
                inline for (&.{ "create", "put", "read", "update", "delete", "list" }) |field| {
                    if (@field(rsrc, field)) |oid| try shape_queue.writeItem(oid);
                }

                try shape_queue.write(rsrc.operations);
                try shape_queue.write(rsrc.collection_ops);
                try shape_queue.write(rsrc.resources);
                // TODO: Should evaluate `identifiers` and `properties`?
            },
            .service => |srvc| {
                try shape_queue.write(srvc.operations);
                try shape_queue.write(srvc.resources);
            },
            .int_enum, .str_enum => try data_shapes.append(id),
            .list => |target| try shape_queue.writeItem(target),
            .map => |targets| {
                try data_shapes.append(id);
                try shape_queue.write(&targets);
            },
            .tagged_uinon, .structure => |fields| {
                var is_error = false;
                if (traits.get(id)) |trts| for (0..trts.len) |i| {
                    if (trts[i].id != error_trait_id) continue;
                    is_error = true;
                    break;
                };

                if (!is_error) try data_shapes.append(id);
                try shape_queue.write(fields);
            },
            .target => |tid| try shape_queue.writeItem(tid),
            // TODO: String may be an enum!
            .boolean, .byte, .short, .integer, .long, .float, .double, .blob, .string => {},
            else => |t| {
                // TODO: unit, big_integer, big_decimal, timestamp, document,
                std.log.warn("Unimplemented shape filter `{}`", .{t});
            },
        }
    }

    return .{ try operations.toOwnedSlice(), try data_shapes.toOwnedSlice() };
}

pub fn deinit(self: *Self) void {
    self.model_meta.deinit(self.arena);
    self.model_shapes.deinit(self.arena);
    self.model_names.deinit(self.arena);
    self.model_traits.deinit(self.arena);
    self.model_mixins.deinit(self.arena);
}

//
// Names
//

pub const NameFormat = enum {
    /// field_name (snake case)
    field,
    /// functionName (camel case)
    function,
    /// TypeName (pascal case)
    type,
    // CONSTANT_NAME (scream case)
    constant,
    /// Title Name (title case)
    title,
};

pub fn getShapeNameRaw(self: Self, id: SmithyId) ![]const u8 {
    return self.model_names.get(id) orelse error.NameNotFound;
}

pub fn getShapeName(self: Self, id: SmithyId, format: NameFormat) ![]const u8 {
    const raw = self.model_names.get(id) orelse return error.NameNotFound;
    return switch (format) {
        .type => raw, // we assume shape names are already in pascal case
        .field => name_util.snakeCase(self.arena, raw),
        .function => name_util.camelCase(self.arena, raw),
        .constant => name_util.screamCase(self.arena, raw),
        .title => name_util.titleCase(self.arena, raw),
    };
}

test "names" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const foobar_id = SmithyId.of("test.simple#FooBar");
    var symbols: Self = blk: {
        var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
        errdefer shapes.deinit(arena_alloc);
        try shapes.put(arena_alloc, foobar_id, .boolean);

        var names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{};
        errdefer names.deinit(arena_alloc);
        try names.put(arena_alloc, foobar_id, "FooBar");

        break :blk Self{
            .arena = arena_alloc,
            .service_id = SmithyId.NULL,
            .model_meta = .{},
            .model_shapes = shapes,
            .model_names = names,
            .model_traits = .{},
            .model_mixins = .{},
        };
    };
    defer symbols.deinit();

    try testing.expectEqualStrings("foo_bar", try symbols.getShapeName(foobar_id, .field));
    try testing.expectEqualStrings("fooBar", try symbols.getShapeName(foobar_id, .function));
    try testing.expectEqualStrings("FooBar", try symbols.getShapeName(foobar_id, .type));
    try testing.expectEqualStrings("FOO_BAR", try symbols.getShapeName(foobar_id, .constant));
    try testing.expectEqualStrings("Foo Bar", try symbols.getShapeName(foobar_id, .title));
    try testing.expectError(error.NameNotFound, symbols.getShapeName(SmithyId.of("test#undefined"), .type));
}

//
// Model
//

pub fn getMeta(self: Self, key: SmithyId) ?SmithyMeta {
    return self.model_meta.get(key);
}

pub fn getMixins(self: Self, shape_id: SmithyId) ?[]const SmithyId {
    return self.model_mixins.get(shape_id);
}

pub fn getShape(self: Self, id: SmithyId) !SmithyType {
    return self.model_shapes.get(id) orelse error.ShapeNotFound;
}

pub fn getShapeUnwrap(self: Self, id: SmithyId) !SmithyType {
    switch (id) {
        // zig fmt: off
            inline .unit, .blob, .boolean, .string, .byte, .short, .integer, .long,
            .float, .double, .big_integer, .big_decimal, .timestamp, .document =>
                |t| return std.enums.nameCast(SmithyType, t),
            // zig fmt: on
        else => {
            return switch (try self.getShape(id)) {
                .target => |t| self.getShape(t),
                else => |t| t,
            };
        },
    }
}

pub fn getTraits(self: Self, shape_id: SmithyId) ?TraitsProvider {
    const traits = self.model_traits.get(shape_id) orelse return null;
    return TraitsProvider{ .values = traits };
}

pub fn hasTrait(self: Self, shape_id: SmithyId, trait_id: SmithyId) bool {
    const traits = self.getTraits(shape_id) orelse return false;
    return traits.has(trait_id);
}

pub fn getTrait(
    self: Self,
    comptime T: type,
    shape_id: SmithyId,
    trait_id: SmithyId,
) ?TraitsProvider.TraitReturn(T) {
    const traits = self.getTraits(shape_id) orelse return null;
    return traits.get(T, trait_id);
}

pub fn getTraitOpaque(self: Self, shape_id: SmithyId, trait_id: SmithyId) ?*const anyopaque {
    const traits = self.getTraits(shape_id) orelse return null;
    return traits.getOpaque(trait_id);
}

test "model" {
    const int: u8 = 108;
    const shape_foo = SmithyId.of("test.simple#Foo");
    const shape_bar = SmithyId.of("test.simple#Bar");
    const trait_void = SmithyId.of("test.trait#Void");
    const trait_int = SmithyId.of("test.trait#Int");

    var symbols: Self = blk: {
        var meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{};
        errdefer meta.deinit(test_alloc);
        try meta.put(test_alloc, shape_foo, .{ .integer = 108 });

        var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
        errdefer shapes.deinit(test_alloc);
        try shapes.put(test_alloc, shape_foo, .blob);
        try shapes.put(test_alloc, shape_bar, .{ .target = shape_foo });

        var names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{};
        errdefer names.deinit(test_alloc);
        try names.put(test_alloc, shape_foo, "Foo");

        var traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue) = .{};
        errdefer traits.deinit(test_alloc);
        try traits.put(test_alloc, shape_foo, &.{
            .{ .id = trait_void, .value = null },
            .{ .id = trait_int, .value = &int },
        });

        var mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{};
        errdefer mixins.deinit(test_alloc);
        try mixins.put(test_alloc, shape_foo, &.{
            SmithyId.of("test.mixin#Foo"),
            SmithyId.of("test.mixin#Bar"),
        });

        break :blk Self{
            .arena = test_alloc,
            .service_id = SmithyId.NULL,
            .model_meta = meta,
            .model_shapes = shapes,
            .model_names = names,
            .model_traits = traits,
            .model_mixins = mixins,
        };
    };
    defer symbols.deinit();

    try testing.expectEqualDeep(
        SmithyMeta{ .integer = 108 },
        symbols.getMeta(shape_foo),
    );

    try testing.expectEqual(.blob, symbols.getShape(shape_foo));
    try testing.expectError(
        error.ShapeNotFound,
        symbols.getShape(SmithyId.of("test#undefined")),
    );

    try testing.expectEqual(.blob, symbols.getShapeUnwrap(shape_bar));
    try testing.expectError(
        error.ShapeNotFound,
        symbols.getShapeUnwrap(SmithyId.of("test#undefined")),
    );

    try testing.expectEqualStrings("Foo", try symbols.getShapeNameRaw(shape_foo));
    const field_name = try symbols.getShapeName(shape_foo, .field);
    defer test_alloc.free(field_name);
    try testing.expectEqualStrings("foo", field_name);
    try testing.expectError(
        error.NameNotFound,
        symbols.getShapeName(SmithyId.of("test#undefined"), .type),
    );

    try testing.expectEqualDeep(
        &.{ SmithyId.of("test.mixin#Foo"), SmithyId.of("test.mixin#Bar") },
        symbols.getMixins(shape_foo),
    );

    try testing.expectEqualDeep(TraitsProvider{ .values = &.{
        SmithyTaggedValue{ .id = trait_void, .value = null },
        SmithyTaggedValue{ .id = trait_int, .value = &int },
    } }, symbols.getTraits(shape_foo));
}
