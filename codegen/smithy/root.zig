pub const JsonReader = @import("utils/JsonReader.zig");

const symbols_traits = @import("symbols/traits.zig");
pub const TraitsManager = symbols_traits.TraitsManager;

pub const IssuesBag = @import("utils/IssuesBag.zig");

const Parser = @import("Parser.zig");
pub const parseJson = Parser.parseJson;

test {
    _ = IssuesBag;
    _ = JsonReader;
    _ = @import("utils/StackWriter.zig");
    _ = @import("symbols/identity.zig");
    _ = symbols_traits;
    _ = @import("symbols/shapes.zig");
    _ = @import("prelude.zig");
    _ = Parser;
    _ = @import("generate/Markdown.zig");
    _ = @import("generate/Zig.zig");
}
