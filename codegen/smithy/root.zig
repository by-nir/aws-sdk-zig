const syb_id = @import("symbols/identity.zig");
pub usingnamespace syb_id;

const syb_shapes = @import("symbols/shapes.zig");
pub usingnamespace syb_shapes;

const syb_traits = @import("symbols/traits.zig");
pub const TraitsRegistry = syb_traits.TraitsRegistry;

pub const Pipeline = @import("Pipeline.zig");

const parse = @import("parse.zig");
pub const ParsePolicy = parse.Policy;

const generate = @import("generate.zig");
pub const Hooks = generate.Hooks;

pub const Markdown = @import("generate/Markdown.zig");
pub const Zig = @import("generate/Zig.zig");

test {
    _ = @import("utils/names.zig");
    _ = @import("utils/IssuesBag.zig");
    _ = @import("utils/JsonReader.zig");
    _ = @import("utils/StackWriter.zig");
    _ = syb_id;
    _ = syb_traits;
    _ = syb_shapes;
    _ = @import("prelude.zig");
    _ = parse;
    _ = generate;
    _ = Markdown;
    _ = Zig;
    _ = Pipeline;
}
