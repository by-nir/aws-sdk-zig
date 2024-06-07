const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const prelude = @import("../prelude.zig");
const name_util = @import("../utils/names.zig");
const TraitsProvider = @import("traits.zig").TraitsProvider;

pub const IdHashInt = u32;
pub const idHash = std.hash.CityHash32.hash;

pub const SmithyTaggedValue = struct {
    id: SmithyId,
    value: ?*const anyopaque,
};

pub const SmithyRefMapValue = struct {
    name: []const u8,
    shape: SmithyId,
};

/// A 32-bit hash of a Shape ID.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#shape-id)
/// ```
/// smithy.example.foo#ExampleShapeName$memberName
/// └────────┬───────┘ └───────┬──────┘ └────┬───┘
///      Namespace           Shape        Member
///                    └────────────┬────────────┘
///                         Relative shape ID
/// └─────────────────────┬──────────────────────┘
///               Absolute shape ID
/// ```
pub const SmithyId = enum(IdHashInt) {
    pub const NULL: SmithyId = @enumFromInt(0);

    unit = idHash("unitType"),
    blob = idHash("blob"),
    boolean = idHash("boolean"),
    string = idHash("string"),
    str_enum = idHash("enum"),
    byte = idHash("byte"),
    short = idHash("short"),
    integer = idHash("integer"),
    int_enum = idHash("intEnum"),
    long = idHash("long"),
    float = idHash("float"),
    double = idHash("double"),
    big_integer = idHash("bigInteger"),
    big_decimal = idHash("bigDecimal"),
    timestamp = idHash("timestamp"),
    document = idHash("document"),
    list = idHash("list"),
    map = idHash("map"),
    structure = idHash("structure"),
    tagged_uinon = idHash("union"),
    operation = idHash("operation"),
    resource = idHash("resource"),
    service = idHash("service"),
    apply = idHash("apply"),
    _,

    /// Type name or absalute shape id.
    pub fn of(shape_id: []const u8) SmithyId {
        return switch (idHash(shape_id)) {
            idHash(prelude.TYPE_UNIT) => .unit,
            idHash(prelude.TYPE_BLOB) => .blob,
            idHash(prelude.TYPE_STRING) => .string,
            idHash(prelude.TYPE_BOOL), idHash(prelude.PRIMITIVE_BOOL) => .boolean,
            idHash(prelude.TYPE_BYTE), idHash(prelude.PRIMITIVE_BYTE) => .byte,
            idHash(prelude.TYPE_SHORT), idHash(prelude.PRIMITIVE_SHORT) => .short,
            idHash(prelude.TYPE_INT), idHash(prelude.PRIMITIVE_INT) => .integer,
            idHash(prelude.TYPE_LONG), idHash(prelude.PRIMITIVE_LONG) => .long,
            idHash(prelude.TYPE_FLOAT), idHash(prelude.PRIMITIVE_FLOAT) => .float,
            idHash(prelude.TYPE_DOUBLE), idHash(prelude.PRIMITIVE_DOUBLE) => .double,
            idHash(prelude.TYPE_BIGINT) => .big_integer,
            idHash(prelude.TYPE_BIGDEC) => .big_decimal,
            idHash(prelude.TYPE_TIMESTAMP) => .timestamp,
            idHash(prelude.TYPE_DOCUMENT) => .document,
            else => |h| @enumFromInt(h),
        };
    }

    /// `smithy.example.foo#ExampleShapeName$memberName`
    pub fn compose(shape: []const u8, member: []const u8) SmithyId {
        var buffer: [128]u8 = undefined;
        const len = shape.len + member.len + 1;
        std.debug.assert(len <= buffer.len);
        @memcpy(buffer[0..shape.len], shape);
        buffer[shape.len] = '$';
        @memcpy(buffer[shape.len + 1 ..][0..member.len], member);
        return @enumFromInt(idHash(buffer[0..len]));
    }
};

test "SmithyId" {
    try testing.expectEqual(.boolean, SmithyId.of("boolean"));
    try testing.expectEqual(.boolean, SmithyId.of("smithy.api#Boolean"));
    try testing.expectEqual(.boolean, SmithyId.of("smithy.api#PrimitiveBoolean"));
    try testing.expectEqual(.list, SmithyId.of("list"));
    try testing.expectEqual(
        @as(SmithyId, @enumFromInt(0x6f8b5d99)),
        SmithyId.of("smithy.example.foo#ExampleShapeName$memberName"),
    );
    try testing.expectEqual(
        SmithyId.of("smithy.example.foo#ExampleShapeName$memberName"),
        SmithyId.compose("smithy.example.foo#ExampleShapeName", "memberName"),
    );
}

/// A Smithy shape’s type.
pub const SmithyType = union(enum) {
    /// A reference to a shape that is not a member of the prelude.
    target: SmithyId,

    /// The singular unit type in Smithy is similar to Void and None in other languages.
    /// It is used when the input or output of an operation has no meaningful value
    /// or if a union member has no meaningful value. It MUST NOT be referenced
    /// in any other context.
    ///
    /// [Smithy Spec](https://smithy.io/2.0/spec/model.html#unit-type)
    unit,

    //
    // Simple types are types that do not contain nested types or shape references.
    // https://smithy.io/2.0/spec/simple-types.html#simple-types
    //

    /// Uninterpreted binary data.
    blob,
    /// Boolean value type.
    boolean,
    /// UTF-8 encoded string.
    string,
    /// A string with a fixed set of values.
    str_enum: []const SmithyId,
    /// 8-bit signed integer ranging from -128 to 127 (inclusive).
    byte,
    /// 16-bit signed integer ranging from -32,768 to 32,767 (inclusive).
    short,
    /// 32-bit signed integer ranging from -2^31 to (2^31)-1 (inclusive).
    integer,
    /// An integer with a fixed set of values.
    int_enum: []const SmithyId,
    /// 64-bit signed integer ranging from -2^63 to (2^63)-1 (inclusive).
    long,
    /// Single precision IEEE-754 floating point number.
    float,
    /// Double precision IEEE-754 floating point number.
    double,
    /// Arbitrarily large signed integer.
    big_integer,
    /// Arbitrary precision signed decimal number.
    big_decimal,
    /// An instant in time with no UTC offset or timezone.
    timestamp,
    /// Open content that functions as a kind of "any" type.
    document,

    //
    // Aggregate types contain configurable member references to others shapes.
    // https://smithy.io/2.0/spec/aggregate-types.html#aggregate-types
    //

    /// Ordered collection of homogeneous values.
    list: SmithyId,
    /// Map data structure that maps string keys to homogeneous values.
    map: [2]SmithyId,
    /// Fixed set of named heterogeneous members.
    structure: []const SmithyId,
    /// Tagged union data structure that can take on one of several different, but fixed, types.
    tagged_uinon: []const SmithyId,

    //
    // Service types have specific semantics and define services, resources, and operations.
    // https://smithy.io/2.0/spec/service-types.html#service-types
    //

    /// The operation type represents the input, output, and possible errors of an API operation.
    operation: *const SmithyOperation,
    /// Smithy defines a resource as an entity with an identity that has a set of operations.
    resource: *const SmithyResource,
    /// A service is the entry point of an API that aggregates resources and operations together.
    service: *const SmithyService,
};

/// All known Smithy properties.
// NOTICE: If adding more properties, make sure their first 8 characters are unique.
pub const SmithyProperty = enum(u64) {
    collection_ops = parse("collectionOperations"),
    create = parse("create"),
    delete = parse("delete"),
    errors = parse("errors"),
    identifiers = parse("identifiers"),
    input = parse("input"),
    key = parse("key"),
    list = parse("list"),
    member = parse("member"),
    members = parse("members"),
    metadata = parse("metadata"),
    mixins = parse("mixins"),
    operations = parse("operations"),
    output = parse("output"),
    properties = parse("properties"),
    put = parse("put"),
    read = parse("read"),
    rename = parse("rename"),
    resources = parse("resources"),
    shapes = parse("shapes"),
    smithy = parse("smithy"),
    target = parse("target"),
    traits = parse("traits"),
    type = parse("type"),
    update = parse("update"),
    value = parse("value"),
    version = parse("version"),
    _,

    fn parse(str: []const u8) u64 {
        var code: u64 = 0;
        const len = @min(8, str.len);
        @memcpy(std.mem.asBytes(&code)[0..len], str[0..len]);
        return code;
    }

    pub fn of(str: []const u8) SmithyProperty {
        return @enumFromInt(parse(str));
    }
};

test "SmithyProperty" {
    try testing.expectEqual(.collection_ops, SmithyProperty.of("collectionOperations"));
    try testing.expectEqual(.create, SmithyProperty.of("create"));
    try testing.expectEqual(.delete, SmithyProperty.of("delete"));
    try testing.expectEqual(.errors, SmithyProperty.of("errors"));
    try testing.expectEqual(.identifiers, SmithyProperty.of("identifiers"));
    try testing.expectEqual(.input, SmithyProperty.of("input"));
    try testing.expectEqual(.key, SmithyProperty.of("key"));
    try testing.expectEqual(.list, SmithyProperty.of("list"));
    try testing.expectEqual(.member, SmithyProperty.of("member"));
    try testing.expectEqual(.members, SmithyProperty.of("members"));
    try testing.expectEqual(.metadata, SmithyProperty.of("metadata"));
    try testing.expectEqual(.mixins, SmithyProperty.of("mixins"));
    try testing.expectEqual(.operations, SmithyProperty.of("operations"));
    try testing.expectEqual(.output, SmithyProperty.of("output"));
    try testing.expectEqual(.properties, SmithyProperty.of("properties"));
    try testing.expectEqual(.put, SmithyProperty.of("put"));
    try testing.expectEqual(.read, SmithyProperty.of("read"));
    try testing.expectEqual(.rename, SmithyProperty.of("rename"));
    try testing.expectEqual(.resources, SmithyProperty.of("resources"));
    try testing.expectEqual(.shapes, SmithyProperty.of("shapes"));
    try testing.expectEqual(.smithy, SmithyProperty.of("smithy"));
    try testing.expectEqual(.target, SmithyProperty.of("target"));
    try testing.expectEqual(.traits, SmithyProperty.of("traits"));
    try testing.expectEqual(.type, SmithyProperty.of("type"));
    try testing.expectEqual(.update, SmithyProperty.of("update"));
    try testing.expectEqual(.value, SmithyProperty.of("value"));
    try testing.expectEqual(.version, SmithyProperty.of("version"));
    try testing.expectEqual(
        SmithyProperty.parse("U4K4OW4"),
        @intFromEnum(SmithyProperty.of("U4K4OW4")),
    );
}

/// A service is the entry point of an API that aggregates resources and operations together.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#service)
pub const SmithyService = struct {
    /// Defines the optional version of the service.
    version: ?[]const u8 = null,
    /// Binds a set of operation shapes to the service.
    operations: []const SmithyId = &.{},
    /// Binds a set of resource shapes to the service.
    resources: []const SmithyId = &.{},
    /// Defines a list of common errors that every operation bound within the closure of the service can return.
    errors: []const SmithyId = &.{},
    /// Disambiguates shape name conflicts in the
    /// [service closure](https://smithy.io/2.0/spec/service-types.html#service-closure).
    rename: []const SmithyRefMapValue = &.{},
};

/// The operation type represents the input, output, and possible errors of an API operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#resource)
pub const SmithyResource = struct {
    /// Defines a map of identifier string names to Shape IDs used to identify the resource.
    identifiers: []const SmithyRefMapValue = &.{},
    /// Defines a map of property string names to Shape IDs that enumerate the properties of the resource.
    properties: []const SmithyRefMapValue = &.{},
    /// Defines the lifecycle operation used to create a resource using one or more identifiers created by the service.
    create: ?SmithyId = null,
    /// Defines an idempotent lifecycle operation used to create a resource using identifiers provided by the client.
    put: ?SmithyId = null,
    /// Defines the lifecycle operation used to retrieve the resource.
    read: ?SmithyId = null,
    /// Defines the lifecycle operation used to update the resource.
    update: ?SmithyId = null,
    /// Defines the lifecycle operation used to delete the resource.
    delete: ?SmithyId = null,
    /// Defines the lifecycle operation used to list resources of this type.
    list: ?SmithyId = null,
    /// Binds a list of non-lifecycle instance operations to the resource.
    operations: []const SmithyId = &.{},
    /// Binds a list of non-lifecycle collection operations to the resource.
    collection_ops: []const SmithyId = &.{},
    /// Binds a list of resources to this resource as a child resource, forming a containment relationship.
    resources: []const SmithyId = &.{},
};

/// Smithy defines a resource as an entity with an identity that has a set of operations.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#operation)
pub const SmithyOperation = struct {
    /// The input of the operation defined using a shape ID that MUST target a structure.
    input: ?SmithyId = null,
    /// The output of the operation defined using a shape ID that MUST target a structure.
    output: ?SmithyId = null,
    /// The errors that an operation can return.
    errors: []const SmithyId = &.{},
};

/// Node values are JSON-like values used to define metadata and the value of an applied trait.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#node-values)
pub const SmithyMeta = union(enum) {
    /// The lack of a value.
    null,
    /// A UTF-8 string.
    string: []const u8,
    /// A double precision integer number.
    ///
    /// _Note: The original spec does not distinguish between number types._
    integer: i64,
    /// A double precision floating point number.
    ///
    /// _Note: The original spec does not distinguish between number types._
    float: f64,
    /// A Boolean, true or false value.
    boolean: bool,
    /// An array of heterogeneous node values.
    list: []const SmithyMeta,
    /// A object mapping string keys to heterogeneous node values.
    map: []const Pair,

    /// A key-value pair in a Map node.
    pub const Pair = struct {
        key: SmithyId,
        value: SmithyMeta,
    };
};

pub const SymbolsProvider = struct {
    arena: Allocator,
    service_id: SmithyId,
    model_meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta),
    model_shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType),
    model_names: std.AutoHashMapUnmanaged(SmithyId, []const u8),
    model_traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue),
    model_mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId),
    shapes_queue: std.DoublyLinkedList(SmithyId) = .{},
    shapes_visited: std.AutoHashMapUnmanaged(SmithyId, void) = .{},
    service_errors: ?[]const SmithyId = null,

    pub fn deinit(self: *SymbolsProvider) void {
        self.model_meta.deinit(self.arena);
        self.model_shapes.deinit(self.arena);
        self.model_names.deinit(self.arena);
        self.model_traits.deinit(self.arena);
        self.model_mixins.deinit(self.arena);

        self.shapes_visited.deinit(self.arena);
        var node = self.shapes_queue.first;
        while (node) |n| {
            node = n.next;
            self.arena.destroy(n);
        }
    }

    pub fn enqueue(self: *SymbolsProvider, id: SmithyId) !void {
        if (self.shapes_visited.contains(id)) return;
        try self.shapes_visited.put(self.arena, id, void{});
        const node = try self.arena.create(std.DoublyLinkedList(SmithyId).Node);
        node.data = id;
        self.shapes_queue.append(node);
    }

    pub fn next(self: *SymbolsProvider) ?SmithyId {
        const node = self.shapes_queue.popFirst() orelse return null;
        const shape = node.data;
        self.arena.destroy(node);
        return shape;
    }

    /// This will NOT remove an existing shape from the queue.
    pub fn markVisited(self: *SymbolsProvider, id: SmithyId) !void {
        try self.shapes_visited.put(self.arena, id, void{});
    }

    pub fn didVisit(self: SymbolsProvider, id: SmithyId) bool {
        return self.shapes_visited.contains(id);
    }

    pub fn getServiceErrors(self: *SymbolsProvider) ![]const SmithyId {
        if (self.service_errors) |e| {
            return e;
        } else {
            const shape = self.model_shapes.get(self.service_id) orelse {
                return error.ServiceNotFound;
            };
            const errors = shape.service.errors;
            self.service_errors = errors;
            return errors;
        }
    }

    pub fn getMeta(self: SymbolsProvider, key: SmithyId) ?SmithyMeta {
        return self.model_meta.get(key);
    }

    pub fn getMixins(self: SymbolsProvider, shape_id: SmithyId) ?[]const SmithyId {
        return self.model_mixins.get(shape_id);
    }

    pub fn getShape(self: SymbolsProvider, id: SmithyId) !SmithyType {
        return self.model_shapes.get(id) orelse error.ShapeNotFound;
    }

    pub fn getShapeUnwrap(self: SymbolsProvider, id: SmithyId) !SmithyType {
        switch (id) {
            // zig fmt: off
            inline .unit, .blob, .boolean, .string, .byte, .short, .integer, .long,
            .float, .double, .big_integer, .big_decimal, .timestamp, .document =>
                |t| return std.enums.nameCast(SmithyType, t),
            // zig fmt: on
            else => {
                const shape = self.model_shapes.get(id) orelse return error.ShapeNotFound;
                return switch (shape) {
                    .target => |t| self.getShape(t),
                    else => |t| t,
                };
            },
        }
    }

    pub fn getTraits(self: SymbolsProvider, shape_id: SmithyId) ?TraitsProvider {
        const traits = self.model_traits.get(shape_id) orelse return null;
        return TraitsProvider{ .values = traits };
    }

    pub fn hasTrait(self: SymbolsProvider, shape_id: SmithyId, trait_id: SmithyId) bool {
        const traits = self.getTraits(shape_id) orelse return false;
        return traits.has(trait_id);
    }

    pub fn getTrait(
        self: SymbolsProvider,
        comptime T: type,
        shape_id: SmithyId,
        trait_id: SmithyId,
    ) ?TraitsProvider.TraitReturn(T) {
        const traits = self.getTraits(shape_id) orelse return null;
        return traits.get(T, trait_id);
    }

    pub fn getTraitOpaque(self: SymbolsProvider, shape_id: SmithyId, trait_id: SmithyId) ?*const anyopaque {
        const traits = self.getTraits(shape_id) orelse return null;
        return traits.getOpaque(trait_id);
    }

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

    pub fn getShapeName(self: SymbolsProvider, id: SmithyId, format: NameFormat) ![]const u8 {
        const raw = self.model_names.get(id) orelse return error.NameNotFound;
        return switch (format) {
            .type => raw,
            .field => name_util.snakeCase(self.arena, raw),
            .function => name_util.camelCase(self.arena, raw),
            .constant => raw,
            .title => name_util.titleCase(self.arena, raw),
        };
    }

    pub fn getTypeName(self: *SymbolsProvider, id: SmithyId) ![]const u8 {
        return switch (id) {
            .str_enum, .int_enum, .list, .map, .structure, .tagged_uinon, .operation, .resource, .service, .apply => unreachable,
            // A document’s consume should parse it into a meaningful type manually:
            .document => return error.UnexpectedDocumentShape,
            // The union type generator assumes a unit is an empty string:
            .unit => "",
            .boolean => "bool",
            .byte => "i8",
            .short => "i16",
            .integer => "i32",
            .long => "i64",
            .float => "f32",
            .double => "f64",
            .timestamp => "u64",
            .string, .blob => "[]const u8",
            .big_integer, .big_decimal => "[]const u8",
            _ => |shape_id| blk: {
                const shape = self.model_shapes.get(id) orelse {
                    return error.ShapeNotFound;
                };
                switch (shape) {
                    .target => |target| break :blk try self.getTypeName(target),
                    inline .unit,
                    .blob,
                    .boolean,
                    .string,
                    .byte,
                    .short,
                    .integer,
                    .long,
                    .float,
                    .double,
                    .big_integer,
                    .big_decimal,
                    .timestamp,
                    .document,
                    => |_, g| {
                        const type_id = std.enums.nameCast(SmithyId, g);
                        break :blk try self.getTypeName(type_id);
                    },
                    else => {
                        const name = try self.getShapeName(shape_id, .type);
                        try self.enqueue(shape_id);
                        break :blk name;
                    },
                }
            },
        };
    }
};

test "SymbolsProvider: queue" {
    var self = SymbolsProvider{
        .arena = test_alloc,
        .service_id = SmithyId.NULL,
        .model_meta = undefined,
        .model_shapes = undefined,
        .model_names = undefined,
        .model_traits = undefined,
        .model_mixins = undefined,
    };
    defer self.deinit();

    try self.enqueue(SmithyId.of("A"));
    try testing.expectEqualDeep(SmithyId.of("A"), self.next());
    try self.enqueue(SmithyId.of("A"));
    try testing.expectEqual(null, self.next());
    try self.enqueue(SmithyId.of("B"));
    try self.enqueue(SmithyId.of("A"));
    try self.enqueue(SmithyId.of("C"));
    try testing.expectEqualDeep(SmithyId.of("B"), self.next());
    try testing.expectEqualDeep(SmithyId.of("C"), self.next());
    try self.markVisited(SmithyId.of("D"));
    try self.enqueue(SmithyId.of("D"));
    try testing.expectEqual(null, self.next());

    try testing.expect(self.didVisit(SmithyId.of("A")));
    try testing.expect(self.didVisit(SmithyId.of("B")));
    try testing.expect(self.didVisit(SmithyId.of("C")));
    try testing.expect(self.didVisit(SmithyId.of("D")));
    try testing.expect(!self.didVisit(SmithyId.of("E")));
}

test "SymbolsProvider.getSharedErrors" {
    var shapes = std.AutoHashMapUnmanaged(SmithyId, SmithyType){};
    try shapes.put(test_alloc, SmithyId.of("test.serve#Service"), .{
        .service = &.{ .errors = &.{SmithyId.of("test.error#ServiceError")} },
    });

    var self = SymbolsProvider{
        .arena = test_alloc,
        .service_id = SmithyId.of("test.serve#Service"),
        .model_shapes = shapes,
        .model_meta = undefined,
        .model_names = undefined,
        .model_traits = undefined,
        .model_mixins = undefined,
    };
    defer self.deinit();

    const expected = .{SmithyId.of("test.error#ServiceError")};
    try testing.expectEqualDeep(&expected, try self.getServiceErrors());
    try testing.expectEqualDeep(&expected, self.service_errors);
}

test "SymbolsProvider: model" {
    const int: u8 = 108;
    const shape_foo = SmithyId.of("test.simple#Foo");
    const shape_bar = SmithyId.of("test.simple#Bar");
    const trait_void = SmithyId.of("test.trait#Void");
    const trait_int = SmithyId.of("test.trait#Int");

    var symbols: SymbolsProvider = blk: {
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

        break :blk SymbolsProvider{
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

    try testing.expectEqualStrings("Foo", try symbols.getShapeName(shape_foo, .type));
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

test "SymbolsProvider: names" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const foobar_id = SmithyId.of("test.simple#FooBar");
    var symbols: SymbolsProvider = blk: {
        var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
        errdefer shapes.deinit(arena_alloc);
        try shapes.put(arena_alloc, foobar_id, .boolean);

        var names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{};
        errdefer names.deinit(arena_alloc);
        try names.put(arena_alloc, foobar_id, "FooBar");

        break :blk SymbolsProvider{
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
    // try testing.expectEqualStrings("FOO_BAR", try symbols.getShapeName(foobar_id, .constant));
    try testing.expectEqualStrings("Foo Bar", try symbols.getShapeName(foobar_id, .title));
    try testing.expectError(
        error.NameNotFound,
        symbols.getShapeName(SmithyId.of("test#undefined"), .type),
    );

    try testing.expectError(
        error.UnexpectedDocumentShape,
        symbols.getTypeName(SmithyId.document),
    );
    try testing.expectEqualStrings("", try symbols.getTypeName(.unit));
    try testing.expectEqualStrings("bool", try symbols.getTypeName(.boolean));
    try testing.expectEqualStrings("i8", try symbols.getTypeName(.byte));
    try testing.expectEqualStrings("i16", try symbols.getTypeName(.short));
    try testing.expectEqualStrings("i32", try symbols.getTypeName(.integer));
    try testing.expectEqualStrings("i64", try symbols.getTypeName(.long));
    try testing.expectEqualStrings("f32", try symbols.getTypeName(.float));
    try testing.expectEqualStrings("f64", try symbols.getTypeName(.double));
    try testing.expectEqualStrings("u64", try symbols.getTypeName(.timestamp));
    try testing.expectEqualStrings("[]const u8", try symbols.getTypeName(.string));
    try testing.expectEqualStrings("[]const u8", try symbols.getTypeName(.blob));
    try testing.expectEqualStrings("[]const u8", try symbols.getTypeName(.big_integer));
    try testing.expectEqualStrings("[]const u8", try symbols.getTypeName(.big_decimal));
    try testing.expectEqualStrings("bool", try symbols.getTypeName(foobar_id));
}
