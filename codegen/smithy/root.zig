pub const JsonReader = @import("utils/JsonReader.zig");

const prelude = @import("prelude.zig");
const symbols_traits = @import("symbols/traits.zig");
pub const TraitsManager = symbols_traits.TraitsManager;
pub const registerPreludeTraits = prelude.registerTraits;

pub const IssuesBag = @import("utils/IssuesBag.zig");

const parse = @import("parse.zig");
pub const parseJson = parse.parseJson;

const generate = @import("generate.zig");
pub const Options = generate.Options;
pub const ReadmeSlots = generate.ReadmeSlots;
pub const getModelDir = generate.getModelDir;
pub const generateModel = generate.generateModel;

test {
    _ = IssuesBag;
    _ = JsonReader;
    _ = @import("utils/StackWriter.zig");
    _ = @import("symbols/identity.zig");
    _ = symbols_traits;
    _ = @import("symbols/shapes.zig");
    _ = prelude;
    _ = parse;
    _ = generate;
    _ = @import("generate/Markdown.zig");
    _ = @import("generate/Zig.zig");
}
