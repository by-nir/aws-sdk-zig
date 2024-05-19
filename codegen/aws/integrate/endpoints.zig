const smithy = @import("smithy");
const TraitsList = smithy.TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // aws.endpoints#dualStackOnlyEndpoints
    // aws.endpoints#endpointsModifier
    // aws.endpoints#rulesBasedEndpoints
    // aws.endpoints#standardPartitionalEndpoints
    // aws.endpoints#standardRegionalEndpoints
};
