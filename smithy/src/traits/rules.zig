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
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SymbolsProvider = syb.SymbolsProvider;
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.rules#clientContextParams
    // smithy.rules#contextParam
    // smithy.rules#operationContextParams
    // smithy.rules#staticContextParams
    .{ EndpointRuleSet.id, EndpointRuleSet.parse },
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

        value.* = try rls.parse(arena, reader);
        return value;
    }
};

test "EndpointRuleSet" {
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
