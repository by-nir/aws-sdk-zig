//! AWS Protocols
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/protocols/index.html#aws-protocols)

const smithy = @import("smithy");
const TraitsList = smithy.TraitsRegistry;

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // aws.protocols#awsJson1_0
    // aws.protocols#awsJson1_1
    // aws.protocols#awsQuery
    // aws.protocols#awsQueryCompatible
    // aws.protocols#awsQueryError
    // aws.protocols#ec2Query
    // aws.protocols#ec2QueryName
    // aws.protocols#httpChecksum
    // aws.protocols#restJson1
    // aws.protocols#restXml
};
