pub const config = @import("config.zig");

// Model
const model = @import("model.zig");
pub const SmithyId = model.SmithyId;
pub const SmithyType = model.SmithyType;
pub const SmithyMeta = model.SmithyMeta;
pub const SmithyService = model.SmithyService;
pub const SmithyResource = model.SmithyResource;
pub const SmithyOperation = model.SmithyOperation;
pub const SmithyTaggedValue = model.SmithyTaggedValue;
pub const SmithyRefMapValue = model.SmithyRefMapValue;
pub const traits = @import("traits.zig").prelude;

// Pipeline
const pipeline = @import("pipeline.zig");
pub const PipelineTask = pipeline.Pipeline;
pub const PipelineOptions = pipeline.PipelineOptions;
pub const PipelineBehavior = pipeline.PipelineBehavior;
pub const PipelineServiceFilterHook = pipeline.PipelineServiceFilterHook;

// Parse
const parse_issues = @import("parse/issues.zig");
pub const ParseBehavior = parse_issues.ParseBehavior;

// Render
const gen_service = @import("render/service.zig");
pub const ServiceScriptHeadHook = gen_service.ScriptHeadHook;
pub const ServiceReadmeHook = gen_service.ServiceReadmeHook;
pub const ServiceReadmeMetadata = gen_service.ServiceReadmeMetadata;
pub const ServiceAuthSchemesHook = gen_service.ServiceAuthSchemesHook;
const gen_client = @import("render/client.zig");
pub const ClientScriptHeadHook = gen_client.ClientScriptHeadHook;
pub const ClientShapeHeadHook = gen_client.ClientShapeHeadHook;
pub const ClientOperationFuncHook = gen_client.ClientOperationFuncHook;
pub const OperationFunc = gen_client.OperationFunc;
const gen_endpoint = @import("render/client_endpoint.zig");
pub const EndpointScriptHeadHook = gen_endpoint.EndpointScriptHeadHook;
const gen_operation = @import("render/client_operation.zig");
pub const OperationScriptHeadHook = gen_operation.OperationScriptHeadHook;

// Systems
const isu = @import("systems/issues.zig");
pub const IssueBehavior = isu.IssueBehavior;
const trt = @import("systems/traits.zig");
pub const StringTrait = trt.StringTrait;
pub const TraitsRegistry = trt.TraitsRegistry;
const rls = @import("systems/rules.zig");
pub const RuleSet = rls.RuleSet;
pub const RulesFunc = rls.Function;
pub const RulesBuiltIn = rls.BuiltIn;
pub const RulesGenerator = rls.Generator;
pub const RulesArgValue = rls.ArgValue;
pub const RulesFuncsRegistry = rls.FunctionsRegistry;
pub const RulesBuiltInsRegistry = rls.BuiltInsRegistry;
pub const RulesParamKV = rls.StringKV(rls.Parameter);
pub const SymbolsProvider = @import("systems/SymbolsProvider.zig");

// Utils
pub const JsonReader = @import("utils/JsonReader.zig");
pub const name_util = @import("utils/names.zig");

test {
    // Utils
    _ = name_util;
    _ = JsonReader;

    // Model
    _ = model;
    _ = @import("traits.zig");

    // Systems
    _ = SymbolsProvider;
    _ = isu;
    _ = trt;
    _ = rls;

    // Parse
    _ = parse_issues;
    _ = @import("parse/Model.zig");
    _ = @import("parse/props.zig");
    _ = @import("parse/parse.zig");

    // Render
    _ = @import("render/shape.zig");
    _ = gen_operation;
    _ = gen_endpoint;
    _ = gen_client;
    _ = gen_service;

    // Pipeline
    _ = pipeline;
}
