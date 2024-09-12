pub const config = @import("config.zig");

const prelude = @import("prelude.zig");
pub const traits = prelude.traits;

const pipeline = @import("pipeline.zig");
pub const PipelineTask = pipeline.Pipeline;
pub const PipelineOptions = pipeline.PipelineOptions;
pub const PipelineBehavior = pipeline.PipelineBehavior;
pub const PipelineServiceFilterHook = pipeline.PipelineServiceFilterHook;

const parse_issues = @import("parse/issues.zig");
pub const ParseBehavior = parse_issues.ParseBehavior;

const gen_issues = @import("gen/issues.zig");
pub const CodegenBehavior = gen_issues.CodegenBehavior;
const gen_service = @import("gen/service.zig");
pub const ServiceScriptHeadHook = gen_service.ScriptHeadHook;
pub const ServiceReadmeHook = gen_service.ServiceReadmeHook;
pub const ServiceReadmeMetadata = gen_service.ServiceReadmeMetadata;
pub const ServiceAuthSchemesHook = gen_service.ServiceAuthSchemesHook;
const gen_endpoint = @import("gen/endpoint.zig");
pub const EndpointScriptHeadHook = gen_endpoint.EndpointScriptHeadHook;
const gen_client = @import("gen/client.zig");
pub const ClientScriptHeadHook = gen_client.ClientScriptHeadHook;
pub const ClientShapeHeadHook = gen_client.ClientShapeHeadHook;
const gen_resource = @import("gen/resource.zig");
pub const ResourceShapeHeadHook = gen_resource.ResourceShapeHeadHook;
const gen_operation = @import("gen/operation.zig");
pub const OperationShapeHook = gen_operation.OperationShapeHook;
pub const OperationShape = gen_operation.OperationShape;

const syb = @import("systems/symbols.zig");
pub usingnamespace syb;

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

const issues = @import("systems/issues.zig");
pub const IssueBehavior = issues.IssueBehavior;

pub const JsonReader = @import("utils/JsonReader.zig");
pub const name_util = @import("utils/names.zig");

test {
    // Utils
    _ = name_util;
    _ = JsonReader;

    // Systems
    _ = issues;
    _ = syb;
    _ = trt;
    _ = rls;

    // Parse
    _ = parse_issues;
    _ = @import("parse/RawModel.zig");
    _ = @import("parse/parse.zig");

    // Codegen
    _ = gen_issues;
    _ = @import("gen/shape.zig");
    _ = @import("gen/errors.zig");
    _ = gen_operation;
    _ = gen_resource;
    _ = gen_client;
    _ = gen_service;

    // Pipeline
    _ = pipeline;
    _ = prelude;
}
