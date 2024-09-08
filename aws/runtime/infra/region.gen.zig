//
// WARNING
// This file is auto-generated, do not modify it directly!
//

const std = @import("std");

pub const Region = enum {
    /// Africa (Cape Town)
    af_south_1,
    /// Asia Pacific (Hong Kong)
    ap_east_1,
    /// Asia Pacific (Tokyo)
    ap_northeast_1,
    /// Asia Pacific (Seoul)
    ap_northeast_2,
    /// Asia Pacific (Osaka)
    ap_northeast_3,
    /// Asia Pacific (Mumbai)
    ap_south_1,
    /// Asia Pacific (Hyderabad)
    ap_south_2,
    /// Asia Pacific (Singapore)
    ap_southeast_1,
    /// Asia Pacific (Sydney)
    ap_southeast_2,
    /// Asia Pacific (Jakarta)
    ap_southeast_3,
    /// Asia Pacific (Melbourne)
    ap_southeast_4,
    /// AWS Standard global region
    aws_global,
    /// Canada (Central)
    ca_central_1,
    /// Canada West (Calgary)
    ca_west_1,
    /// Europe (Frankfurt)
    eu_central_1,
    /// Europe (Zurich)
    eu_central_2,
    /// Europe (Stockholm)
    eu_north_1,
    /// Europe (Milan)
    eu_south_1,
    /// Europe (Spain)
    eu_south_2,
    /// Europe (Ireland)
    eu_west_1,
    /// Europe (London)
    eu_west_2,
    /// Europe (Paris)
    eu_west_3,
    /// Israel (Tel Aviv)
    il_central_1,
    /// Middle East (UAE)
    me_central_1,
    /// Middle East (Bahrain)
    me_south_1,
    /// South America (Sao Paulo)
    sa_east_1,
    /// US East (N. Virginia)
    us_east_1,
    /// US East (Ohio)
    us_east_2,
    /// US West (N. California)
    us_west_1,
    /// US West (Oregon)
    us_west_2,
    /// AWS China global region
    aws_cn_global,
    /// China (Beijing)
    cn_north_1,
    /// China (Ningxia)
    cn_northwest_1,
    /// AWS GovCloud (US) global region
    aws_us_gov_global,
    /// AWS GovCloud (US-East)
    us_gov_east_1,
    /// AWS GovCloud (US-West)
    us_gov_west_1,
    /// AWS ISO (US) global region
    aws_iso_global,
    /// US ISO East
    us_iso_east_1,
    /// US ISO WEST
    us_iso_west_1,
    /// AWS ISOB (US) global region
    aws_iso_b_global,
    /// US ISOB East (Ohio)
    us_isob_east_1,
    /// EU ISOE West
    eu_isoe_west_1,

    const map = std.StaticStringMap(Region).initComptime(.{
        .{ "af-south-1", .af_south_1 },
        .{ "ap-east-1", .ap_east_1 },
        .{ "ap-northeast-1", .ap_northeast_1 },
        .{ "ap-northeast-2", .ap_northeast_2 },
        .{ "ap-northeast-3", .ap_northeast_3 },
        .{ "ap-south-1", .ap_south_1 },
        .{ "ap-south-2", .ap_south_2 },
        .{ "ap-southeast-1", .ap_southeast_1 },
        .{ "ap-southeast-2", .ap_southeast_2 },
        .{ "ap-southeast-3", .ap_southeast_3 },
        .{ "ap-southeast-4", .ap_southeast_4 },
        .{ "aws-global", .aws_global },
        .{ "ca-central-1", .ca_central_1 },
        .{ "ca-west-1", .ca_west_1 },
        .{ "eu-central-1", .eu_central_1 },
        .{ "eu-central-2", .eu_central_2 },
        .{ "eu-north-1", .eu_north_1 },
        .{ "eu-south-1", .eu_south_1 },
        .{ "eu-south-2", .eu_south_2 },
        .{ "eu-west-1", .eu_west_1 },
        .{ "eu-west-2", .eu_west_2 },
        .{ "eu-west-3", .eu_west_3 },
        .{ "il-central-1", .il_central_1 },
        .{ "me-central-1", .me_central_1 },
        .{ "me-south-1", .me_south_1 },
        .{ "sa-east-1", .sa_east_1 },
        .{ "us-east-1", .us_east_1 },
        .{ "us-east-2", .us_east_2 },
        .{ "us-west-1", .us_west_1 },
        .{ "us-west-2", .us_west_2 },
        .{ "aws-cn-global", .aws_cn_global },
        .{ "cn-north-1", .cn_north_1 },
        .{ "cn-northwest-1", .cn_northwest_1 },
        .{ "aws-us-gov-global", .aws_us_gov_global },
        .{ "us-gov-east-1", .us_gov_east_1 },
        .{ "us-gov-west-1", .us_gov_west_1 },
        .{ "aws-iso-global", .aws_iso_global },
        .{ "us-iso-east-1", .us_iso_east_1 },
        .{ "us-iso-west-1", .us_iso_west_1 },
        .{ "aws-iso-b-global", .aws_iso_b_global },
        .{ "us-isob-east-1", .us_isob_east_1 },
        .{ "eu-isoe-west-1", .eu_isoe_west_1 },
    });

    pub fn parseCode(code: []const u8) ?Region {
        return map.get(code);
    }

    pub fn toCode(self: Region) []const u8 {
        return switch (self) {
            .af_south_1 => "af-south-1",
            .ap_east_1 => "ap-east-1",
            .ap_northeast_1 => "ap-northeast-1",
            .ap_northeast_2 => "ap-northeast-2",
            .ap_northeast_3 => "ap-northeast-3",
            .ap_south_1 => "ap-south-1",
            .ap_south_2 => "ap-south-2",
            .ap_southeast_1 => "ap-southeast-1",
            .ap_southeast_2 => "ap-southeast-2",
            .ap_southeast_3 => "ap-southeast-3",
            .ap_southeast_4 => "ap-southeast-4",
            .aws_global => "aws-global",
            .ca_central_1 => "ca-central-1",
            .ca_west_1 => "ca-west-1",
            .eu_central_1 => "eu-central-1",
            .eu_central_2 => "eu-central-2",
            .eu_north_1 => "eu-north-1",
            .eu_south_1 => "eu-south-1",
            .eu_south_2 => "eu-south-2",
            .eu_west_1 => "eu-west-1",
            .eu_west_2 => "eu-west-2",
            .eu_west_3 => "eu-west-3",
            .il_central_1 => "il-central-1",
            .me_central_1 => "me-central-1",
            .me_south_1 => "me-south-1",
            .sa_east_1 => "sa-east-1",
            .us_east_1 => "us-east-1",
            .us_east_2 => "us-east-2",
            .us_west_1 => "us-west-1",
            .us_west_2 => "us-west-2",
            .aws_cn_global => "aws-cn-global",
            .cn_north_1 => "cn-north-1",
            .cn_northwest_1 => "cn-northwest-1",
            .aws_us_gov_global => "aws-us-gov-global",
            .us_gov_east_1 => "us-gov-east-1",
            .us_gov_west_1 => "us-gov-west-1",
            .aws_iso_global => "aws-iso-global",
            .us_iso_east_1 => "us-iso-east-1",
            .us_iso_west_1 => "us-iso-west-1",
            .aws_iso_b_global => "aws-iso-b-global",
            .us_isob_east_1 => "us-isob-east-1",
            .eu_isoe_west_1 => "eu-isoe-west-1",
        };
    }
};
