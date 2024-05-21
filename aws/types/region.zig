const std = @import("std");

var shared = Region.sdk_default;

pub const SharedRegion = struct {
    pub fn get() Region {
        return shared;
    }

    pub fn set(region: Region) void {
        shared = region;
    }
};

pub const Region = enum(u64) {
    pub const Mask = std.enums.EnumSet(Region);

    pub const sdk_default = Region.us_east_1;

    /// US East (N. Virginia)
    us_east_1 = 1 << 0,
    /// US East (Ohio)
    us_east_2 = 1 << 13,
    /// US West (N. California)
    us_west_1 = 1 << 2,
    /// US West (Oregon)
    us_west_2 = 1 << 6,
    /// AWS GovCloud (US-East)
    us_gov_east_1 = 1 << 19,
    /// AWS GovCloud (US-West)
    us_gov_west_1 = 1 << 5,
    /// Canada (Central)
    ca_central_1 = 1 << 14,
    /// Canada West (Calgary)
    ca_west_1 = 1 << 32,
    /// South America (São Paulo)
    sa_east_1 = 1 << 7,
    /// Europe (Stockholm)
    eu_north_1 = 1 << 20,
    /// Europe (Ireland)
    eu_west_1 = 1 << 1,
    /// Europe (London)
    eu_west_2 = 1 << 15,
    /// Europe (Paris)
    eu_west_3 = 1 << 17,
    /// Europe (Milan)
    eu_south_1 = 1 << 24,
    /// Europe (Spain)
    eu_south_2 = 1 << 28,
    /// Europe (Frankfurt)
    eu_central_1 = 1 << 10,
    /// Europe (Zurich)
    eu_central_2 = 1 << 27,
    /// Israel (Tel Aviv)
    il_central_1 = 1 << 31,
    /// Middle East (Bahrain)
    me_south_1 = 1 << 22,
    /// Middle East (UAE)
    me_central_1 = 1 << 26,
    /// Africa (Cape Town)
    af_south_1 = 1 << 23,
    /// Asia Pacific (Mumbai)
    ap_south_1 = 1 << 12,
    /// Asia Pacific (Hyderabad)
    ap_south_2 = 1 << 29,
    /// Asia Pacific (Hong Kong)
    ap_east_1 = 1 << 21,
    /// Asia Pacific (Tokyo)
    ap_northeast_1 = 1 << 4,
    /// Asia Pacific (Seoul)
    ap_northeast_2 = 1 << 11,
    /// Asia Pacific (Osaka)
    ap_northeast_3 = 1 << 18,
    /// Asia Pacific (Singapore)
    ap_southeast_1 = 1 << 3,
    /// Asia Pacific (Sydney)
    ap_southeast_2 = 1 << 8,
    /// Asia Pacific (Jakarta)
    ap_southeast_3 = 1 << 25,
    /// Asia Pacific (Melbourne)
    ap_southeast_4 = 1 << 30,
    // /// China (Beijing)
    // cn_north_1 = 1 << 9,
    // /// China (Ningxia)
    // cn_northwest_1 = 1 << 16,

    pub fn code(self: Region) []const u8 {
        return switch (self) {
            .us_east_1 => "us-east-1",
            .us_east_2 => "us-east-2",
            .us_west_1 => "us-west-1",
            .us_west_2 => "us-west-2",
            .us_gov_east_1 => "us-gov-east-1",
            .us_gov_west_1 => "us-gov-west-1",
            .ca_central_1 => "ca-central-1",
            .ca_west_1 => "ca-west-1",
            .sa_east_1 => "sa-east-1",
            .eu_north_1 => "eu-north-1",
            .eu_west_1 => "eu-west-1",
            .eu_west_2 => "eu-west-2",
            .eu_west_3 => "eu-west-3",
            .eu_south_1 => "eu-south-1",
            .eu_south_2 => "eu-south-2",
            .eu_central_1 => "eu-central-1",
            .eu_central_2 => "eu-central-2",
            .il_central_1 => "il-central-1",
            .me_south_1 => "me-south-1",
            .me_central_1 => "me-central-1",
            .af_south_1 => "af-south-1",
            .ap_south_1 => "ap-south-1",
            .ap_south_2 => "ap-south-2",
            .ap_east_1 => "ap-east-1",
            .ap_northeast_1 => "ap-northeast-1",
            .ap_northeast_2 => "ap-northeast-2",
            .ap_northeast_3 => "ap-northeast-3",
            .ap_southeast_1 => "ap-southeast-1",
            .ap_southeast_2 => "ap-southeast-2",
            .ap_southeast_3 => "ap-southeast-3",
            .ap_southeast_4 => "ap-southeast-4",
            // .cn_north_1 => "cn-north-1",
            // .cn_northwest_1 => "cn-northwest-1",
        };
    }

    pub fn title(self: Region) []const u8 {
        return switch (self) {
            .us_east_1 => "N. Virginia (US East 1)",
            .us_east_2 => "Ohio (US East 2)",
            .us_west_1 => "N. California (US West 1)",
            .us_west_2 => "Oregon (US West 2)",
            .us_gov_east_1 => "GovCloud East (US East 1)",
            .us_gov_west_1 => "GovCloud West (US West 1)",
            .ca_central_1 => "Central (CA Central 1)",
            .ca_west_1 => "Calgary (CA West 1)",
            .sa_east_1 => "São Paulo (SA East 1)",
            .eu_north_1 => "Stockholm (EU North 1)",
            .eu_west_1 => "Ireland (EU West 1)",
            .eu_west_2 => "London (EU West 2)",
            .eu_west_3 => "Paris (EU West 3)",
            .eu_south_1 => "Milan (EU South 1)",
            .eu_south_2 => "Spain (EU South 1)",
            .eu_central_1 => "Frankfurt (EU Central 1)",
            .eu_central_2 => "Zurich (EU Central 2)",
            .il_central_1 => "Tel Aviv (IL Central 1)",
            .me_south_1 => "Bahrain (ME South 1)",
            .me_central_1 => "UAE (ME Central 1)",
            .af_south_1 => "Cape Town (AF South 1)",
            .ap_south_1 => "Mumbai (AP South 1)",
            .ap_south_2 => "Hyderabad (AP South 2)",
            .ap_east_1 => "Hong Kong (AP East 1)",
            .ap_northeast_1 => "Tokyo (AP Northeast 1)",
            .ap_northeast_2 => "Seoul (AP Northeast 2)",
            .ap_northeast_3 => "Osaka (AP Northeast 3)",
            .ap_southeast_1 => "Singapore (AP Southeast 1)",
            .ap_southeast_2 => "Sydney (AP Southeast 2)",
            .ap_southeast_3 => "Jakarta (AP Southeast 3)",
            .ap_southeast_4 => "Melbourne (AP Southeast 4)",
            // .cn_north_1 => "Beijing (CN North 1)",
            // .cn_northwest_1 => "Ningxia (CN Northwest 1)",
        };
    }
};
