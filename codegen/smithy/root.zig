pub const JsonReader = @import("utils/JsonReader.zig");

const trait = @import("semantic/trait.zig");
pub const TraitManager = trait.TraitManager;

const Parser = @import("Parser.zig");
pub const parseJson = Parser.parseJson;

test {
    _ = JsonReader;
    _ = @import("semantic/identity.zig");
    _ = trait;
    _ = @import("prelude.zig");
    _ = Parser;
}
