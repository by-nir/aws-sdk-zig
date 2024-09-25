const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const zig = @import("razdaz").zig;
const srvc = @import("service.zig");
const cfg = @import("../config.zig");
const SmithyId = @import("../model.zig").SmithyId;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const trt_rules = @import("../traits/rules.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const EndpointScriptHeadHook = jobz.Task.Hook("Smithy Endpoint Script Head", anyerror!void, &.{*zig.ContainerBuild});

pub const ClientEndpoint = srvc.ScriptCodegen.Task("Smithy Client Endpoint Codegen", clientEndpointTask, .{
    .injects = &.{ SymbolsProvider, RulesEngine },
});
fn clientEndpointTask(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    rules_engine: *RulesEngine,
    bld: *zig.ContainerBuild,
) anyerror!void {
    const rule_set = trt_rules.EndpointRuleSet.get(symbols, symbols.service_id) orelse {
        return error.MissingEndpointRuleSet;
    };

    try bld.constant("IS_TEST").assign(bld.x.import("builtin").dot().id("is_test"));

    if (self.hasOverride(EndpointScriptHeadHook)) {
        try self.evaluate(EndpointScriptHeadHook, .{bld});
    }

    var rulesgen = try rules_engine.getGenerator(self.alloc(), rule_set.parameters);

    const context = .{ .alloc = self.alloc(), .rulesgen = &rulesgen };
    try bld.public().constant(cfg.endpoint_config_type).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
            try ctx.rulesgen.generateParametersFields(b);
        }
    }.f));

    try rulesgen.generateResolver(bld, rule_set.rules);

    if (trt_rules.EndpointTests.get(symbols, symbols.service_id)) |cases| {
        try rulesgen.generateTests(bld, cases);
    }
}

test ClientEndpoint {
    var tester = try jobz.PipelineTester.init(.{});
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), .service);
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    var rules_engine = try RulesEngine.init(test_alloc, &.{}, &.{});
    defer rules_engine.deinit(test_alloc);
    _ = try tester.provideService(&rules_engine, null);

    symbols.service_id = SmithyId.of("test.serve#Service");
    try srvc.expectServiceScript(
        \\const IS_TEST = @import("builtin").is_test;
        \\
        \\pub const EndpointConfig = struct {
        \\    foo: ?bool = null,
        \\};
        \\
        \\pub fn resolve(allocator: Allocator, config: EndpointConfig) !smithy.Endpoint {
        \\    var local_buffer: [512]u8 = undefined;
        \\
        \\    var fixed_buffer = std.heap.FixedBufferAllocator.init(&local_buffer);
        \\
        \\    const scratch_alloc = fixed_buffer.allocator();
        \\
        \\    _ = scratch_alloc;
        \\
        \\    var did_pass = false;
        \\
        \\    if (!IS_TEST) std.log.err("baz", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
        \\
        \\test "Foo" {
        \\    const config = EndpointConfig{};
        \\
        \\    const endpoint = resolve(std.testing.allocator, config);
        \\
        \\    try std.testing.expectError(error.ReachedErrorRule, endpoint);
        \\}
    , ClientEndpoint, tester.pipeline, .{});
}
