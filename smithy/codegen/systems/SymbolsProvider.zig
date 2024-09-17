const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const TraitsProvider = @import("traits.zig").TraitsProvider;
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyType = mdl.SmithyType;
const SmithyMeta = mdl.SmithyMeta;
const SmithyTaggedValue = mdl.SmithyTaggedValue;
const Model = @import("../parse/Model.zig");
const name_util = @import("../utils/names.zig");
const AuthId = @import("../traits/auth.zig").AuthId;
const error_trait_id = @import("../traits/refine.zig").Error.id;

const Self = @This();
pub const NameCase = name_util.Case;
pub const NameOptions = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
};

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
            .boolean, .byte, .short, .integer, .long, .float, .double, .string, .blob => {},
            .target => |tid| try shape_queue.writeItem(tid),
            .int_enum, .str_enum, .trt_enum => try data_shapes.append(id),
            .tagged_union => |fields| {
                try data_shapes.append(id);
                try shape_queue.write(fields);
            },
            .list => |target| try shape_queue.writeItem(target),
            .map => |targets| try shape_queue.write(&targets),
            .structure => |fields| {
                var is_error = false;
                if (traits.get(id)) |trts| for (0..trts.len) |i| {
                    if (trts[i].id != error_trait_id) continue;
                    is_error = true;
                    break;
                };

                if (!is_error) try data_shapes.append(id);
                try shape_queue.write(fields);
            },
            .operation => |op| {
                try operations.append(id);
                if (op.input) |tid| try shape_queue.write(shapes.get(tid).?.structure);
                if (op.output) |tid| try shape_queue.write(shapes.get(tid).?.structure);
                try shape_queue.write(op.errors);
            },
            .resource => |rsrc| {
                // We ignore `identifiers` & `properties` shapes
                inline for (&.{ "create", "put", "read", "update", "delete", "list" }) |field| {
                    if (@field(rsrc, field)) |oid| try shape_queue.writeItem(oid);
                }

                try shape_queue.write(rsrc.operations);
                try shape_queue.write(rsrc.collection_ops);
                try shape_queue.write(rsrc.resources);
            },
            .service => |srvc| {
                try shape_queue.write(srvc.operations);
                try shape_queue.write(srvc.resources);
            },
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

pub fn getShapeName(self: Self, id: SmithyId, comptime case: NameCase, comptime options: NameOptions) ![]const u8 {
    const raw = self.model_names.get(id) orelse return error.NameNotFound;
    const has_extras = options.prefix.len + options.suffix.len > 0;
    if (case == .pascal and !has_extras) return raw;

    return std.fmt.allocPrint(self.arena, options.prefix ++ "{s}" ++ options.suffix, .{switch (case) {
        .pascal => raw,
        else => name_util.CaseFormatter(case){ .value = raw },
    }});
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

test Self {
    const int: u8 = 108;
    const shape_foo = SmithyId.of("test.simple#Foo");
    const shape_bar = SmithyId.of("test.simple#Bar");
    const shape_bazqux = SmithyId.of("test.simple#BazQux");
    const trait_void = SmithyId.of("test.trait#Void");
    const trait_int = SmithyId.of("test.trait#Int");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var symbols: Self = blk: {
        var meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{};
        try meta.put(arena_alloc, shape_foo, .{ .integer = 108 });

        var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
        errdefer shapes.deinit(arena_alloc);
        try shapes.put(arena_alloc, shape_foo, .blob);
        try shapes.put(arena_alloc, shape_bar, .{ .target = shape_foo });
        try shapes.put(arena_alloc, shape_bazqux, .boolean);

        var names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{};
        errdefer names.deinit(arena_alloc);
        try names.put(arena_alloc, shape_foo, "Foo");
        try names.put(arena_alloc, shape_bazqux, "BazQux");

        var traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue) = .{};
        errdefer traits.deinit(arena_alloc);
        try traits.put(arena_alloc, shape_foo, &.{
            .{ .id = trait_void, .value = null },
            .{ .id = trait_int, .value = &int },
        });

        var mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{};
        errdefer mixins.deinit(arena_alloc);
        try mixins.put(arena_alloc, shape_foo, &.{
            SmithyId.of("test.mixin#Foo"),
            SmithyId.of("test.mixin#Bar"),
        });

        break :blk Self{
            .arena = arena_alloc,
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
    try testing.expectError(error.ShapeNotFound, symbols.getShape(SmithyId.of("test#undefined")));

    try testing.expectEqual(.blob, symbols.getShapeUnwrap(shape_bar));
    try testing.expectError(error.ShapeNotFound, symbols.getShapeUnwrap(SmithyId.of("test#undefined")));

    try testing.expectEqualStrings("Foo", try symbols.getShapeName(shape_foo, .pascal, .{}));
    try testing.expectEqualStrings("foo", try symbols.getShapeName(shape_foo, .snake, .{}));
    try testing.expectError(error.NameNotFound, symbols.getShapeName(SmithyId.of("test#undefined"), .pascal, .{}));

    try testing.expectEqualDeep(
        &.{ SmithyId.of("test.mixin#Foo"), SmithyId.of("test.mixin#Bar") },
        symbols.getMixins(shape_foo),
    );

    try testing.expectEqualDeep(TraitsProvider{ .values = &.{
        SmithyTaggedValue{ .id = trait_void, .value = null },
        SmithyTaggedValue{ .id = trait_int, .value = &int },
    } }, symbols.getTraits(shape_foo));

    const extras = NameOptions{ .prefix = "<", .suffix = ">" };

    try testing.expectEqualStrings("baz_qux", try symbols.getShapeName(shape_bazqux, .snake, .{}));
    try testing.expectEqualStrings("<baz_qux>", try symbols.getShapeName(shape_bazqux, .snake, extras));

    try testing.expectEqualStrings("bazQux", try symbols.getShapeName(shape_bazqux, .camel, .{}));
    try testing.expectEqualStrings("<bazQux>", try symbols.getShapeName(shape_bazqux, .camel, extras));

    try testing.expectEqualStrings("BAZ_QUX", try symbols.getShapeName(shape_bazqux, .scream, .{}));
    try testing.expectEqualStrings("<BAZ_QUX>", try symbols.getShapeName(shape_bazqux, .scream, extras));

    try testing.expectEqualStrings("Baz Qux", try symbols.getShapeName(shape_bazqux, .title, .{}));
    try testing.expectEqualStrings("<Baz Qux>", try symbols.getShapeName(shape_bazqux, .title, extras));

    try testing.expectEqualStrings("BazQux", try symbols.getShapeName(shape_bazqux, .pascal, .{}));
    try testing.expectEqualStrings("<BazQux>", try symbols.getShapeName(shape_bazqux, .pascal, extras));

    try testing.expectError(error.NameNotFound, symbols.getShapeName(SmithyId.of("test#undefined"), .pascal, .{}));
}
