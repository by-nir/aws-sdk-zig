//! The Smithy rules engine provides service owners with a collection of traits
//! and components to define rule sets. Rule sets specify a type of client
//! behavior to be resolved at runtime, for example rules-based endpoint or
//! authentication scheme resolution.
//!
//! [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/index.html)
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const JsonReader = @import("../utils/JsonReader.zig");
const rls = @import("../systems/rules.zig");
const SmithyId = @import("../model.zig").SmithyId;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.rules#clientContextParams
    // smithy.rules#contextParam
    // smithy.rules#operationContextParams
    // smithy.rules#staticContextParams
    .{ EndpointRuleSet.id, EndpointRuleSet.parse },
    .{ EndpointTests.id, EndpointTests.parse },
};

/// Defines a rule set for deriving service endpoints at runtime.
///
/// [Smithy Spec](https://smithy.io/2.0/additional-specs/rules-engine/specification.html#smithy-rules-endpointruleset-trait)
pub const EndpointRuleSet = struct {
    pub const id = SmithyId.of("smithy.rules#endpointRuleSet");

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?*const rls.RuleSet {
        return symbols.getTrait(rls.RuleSet, shape_id, id);
    }

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(rls.RuleSet);
        errdefer arena.destroy(value);

        value.* = try rls.parseRuleSet(arena, reader);
        return value;
    }
};

test EndpointRuleSet {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\  "version": "1.0",
        \\  "parameters": {},
        \\  "rules": []
        \\}
    );
    const value: *const rls.RuleSet = @alignCast(@ptrCast(EndpointRuleSet.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&rls.RuleSet{}, value);
}

/// Currently undocumented by the Smithy Spec.
pub const EndpointTests = struct {
    pub const id = SmithyId.of("smithy.rules#endpointTests");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const tests = try rls.parseTests(arena, reader);
        return tests.ptr;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?[]const rls.TestCase {
        const trait = symbols.getTraitOpaque(shape_id, id);
        return if (trait) |ptr| cast(ptr) else null;
    }

    fn cast(ptr: *const anyopaque) ?[]const rls.TestCase {
        const items: [*]const rls.TestCase = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        while (true) : (i += 1) {
            const item = items[i];
            if (item.expect == .invalid) return items[0..i];
        }
        unreachable;
    }
};

test EndpointTests {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\  "testCases": [],
        \\  "version": "1.0"
        \\}
    );
    const value: ?[]const rls.TestCase = EndpointTests.cast(EndpointTests.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    });
    reader.deinit();

    try testing.expectEqualDeep(&[_]rls.TestCase{}, value);
}
