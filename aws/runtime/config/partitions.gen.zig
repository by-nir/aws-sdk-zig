//
// WARNING
// This file is auto-generated, do not modify it directly!
//

const std = @import("std");

const Partition = @import("endpoint.zig").Partition;

const prtn_aws = Partition{
    .name = "aws",
    .dns_suffix = "amazonaws.com",
    .dual_stack_dns_suffix = "api.aws",
    .supports_fips = true,
    .supports_dual_stack = true,
    .implicit_global_region = "us-east-1",
};

fn matchAws(code: []const u8) bool {
    var rest = code[1 .. code.len - 1];

    if (!matchAny(&rest, .{
        .{"us"},
        .{"eu"},
        .{"ap"},
        .{"sa"},
        .{"ca"},
        .{"me"},
        .{"af"},
        .{"il"},
    })) return false;

    if (!matchDash(&rest)) return false;

    if (!matchWord(&rest)) return false;

    if (!matchDash(&rest)) return false;

    if (!matchNumber(&rest)) return false;

    return true;
}

const prtn_aws_cn = Partition{
    .name = "aws-cn",
    .dns_suffix = "amazonaws.com.cn",
    .dual_stack_dns_suffix = "api.amazonwebservices.com.cn",
    .supports_fips = true,
    .supports_dual_stack = true,
    .implicit_global_region = "cn-northwest-1",
};

fn matchAwsCn(code: []const u8) bool {
    var rest = code[1 .. code.len - 1];

    if (!matchString(&rest, "cn")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchWord(&rest)) return false;

    if (!matchDash(&rest)) return false;

    if (!matchNumber(&rest)) return false;

    return true;
}

const prtn_aws_us_gov = Partition{
    .name = "aws-us-gov",
    .dns_suffix = "amazonaws.com",
    .dual_stack_dns_suffix = "api.aws",
    .supports_fips = true,
    .supports_dual_stack = true,
    .implicit_global_region = "us-gov-west-1",
};

fn matchAwsUsGov(code: []const u8) bool {
    var rest = code[1 .. code.len - 1];

    if (!matchString(&rest, "us")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchString(&rest, "gov")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchWord(&rest)) return false;

    if (!matchDash(&rest)) return false;

    if (!matchNumber(&rest)) return false;

    return true;
}

const prtn_aws_iso = Partition{
    .name = "aws-iso",
    .dns_suffix = "c2s.ic.gov",
    .dual_stack_dns_suffix = "c2s.ic.gov",
    .supports_fips = true,
    .supports_dual_stack = false,
    .implicit_global_region = "us-iso-east-1",
};

fn matchAwsIso(code: []const u8) bool {
    var rest = code[1 .. code.len - 1];

    if (!matchString(&rest, "us")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchString(&rest, "iso")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchWord(&rest)) return false;

    if (!matchDash(&rest)) return false;

    if (!matchNumber(&rest)) return false;

    return true;
}

const prtn_aws_iso_b = Partition{
    .name = "aws-iso-b",
    .dns_suffix = "sc2s.sgov.gov",
    .dual_stack_dns_suffix = "sc2s.sgov.gov",
    .supports_fips = true,
    .supports_dual_stack = false,
    .implicit_global_region = "us-isob-east-1",
};

fn matchAwsIsoB(code: []const u8) bool {
    var rest = code[1 .. code.len - 1];

    if (!matchString(&rest, "us")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchString(&rest, "isob")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchWord(&rest)) return false;

    if (!matchDash(&rest)) return false;

    if (!matchNumber(&rest)) return false;

    return true;
}

const prtn_aws_iso_e = Partition{
    .name = "aws-iso-e",
    .dns_suffix = "cloud.adc-e.uk",
    .dual_stack_dns_suffix = "cloud.adc-e.uk",
    .supports_fips = true,
    .supports_dual_stack = false,
    .implicit_global_region = "eu-isoe-west-1",
};

fn matchAwsIsoE(code: []const u8) bool {
    var rest = code[1 .. code.len - 1];

    if (!matchString(&rest, "eu")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchString(&rest, "isoe")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchWord(&rest)) return false;

    if (!matchDash(&rest)) return false;

    if (!matchNumber(&rest)) return false;

    return true;
}

const prtn_aws_iso_f = Partition{
    .name = "aws-iso-f",
    .dns_suffix = "csp.hci.ic.gov",
    .dual_stack_dns_suffix = "csp.hci.ic.gov",
    .supports_fips = true,
    .supports_dual_stack = false,
    .implicit_global_region = "us-isof-south-1",
};

fn matchAwsIsoF(code: []const u8) bool {
    var rest = code[1 .. code.len - 1];

    if (!matchString(&rest, "us")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchString(&rest, "isof")) return false;

    if (!matchDash(&rest)) return false;

    if (!matchWord(&rest)) return false;

    if (!matchDash(&rest)) return false;

    if (!matchNumber(&rest)) return false;

    return true;
}

const partitions = std.StaticStringMap(*const Partition).initComptime(.{
    .{ "af-south-1", &prtn_aws },
    .{ "ap-east-1", &prtn_aws },
    .{ "ap-northeast-1", &prtn_aws },
    .{ "ap-northeast-2", &prtn_aws },
    .{ "ap-northeast-3", &prtn_aws },
    .{ "ap-south-1", &prtn_aws },
    .{ "ap-south-2", &prtn_aws },
    .{ "ap-southeast-1", &prtn_aws },
    .{ "ap-southeast-2", &prtn_aws },
    .{ "ap-southeast-3", &prtn_aws },
    .{ "ap-southeast-4", &prtn_aws },
    .{ "aws-global", &prtn_aws },
    .{ "ca-central-1", &prtn_aws },
    .{ "ca-west-1", &prtn_aws },
    .{ "eu-central-1", &prtn_aws },
    .{ "eu-central-2", &prtn_aws },
    .{ "eu-north-1", &prtn_aws },
    .{ "eu-south-1", &prtn_aws },
    .{ "eu-south-2", &prtn_aws },
    .{ "eu-west-1", &prtn_aws },
    .{ "eu-west-2", &prtn_aws },
    .{ "eu-west-3", &prtn_aws },
    .{ "il-central-1", &prtn_aws },
    .{ "me-central-1", &prtn_aws },
    .{ "me-south-1", &prtn_aws },
    .{ "sa-east-1", &prtn_aws },
    .{ "us-east-1", &prtn_aws },
    .{ "us-east-2", &prtn_aws },
    .{ "us-west-1", &prtn_aws },
    .{ "us-west-2", &prtn_aws },
    .{ "aws-cn-global", &prtn_aws_cn },
    .{ "cn-north-1", &prtn_aws_cn },
    .{ "cn-northwest-1", &prtn_aws_cn },
    .{ "aws-us-gov-global", &prtn_aws_us_gov },
    .{ "us-gov-east-1", &prtn_aws_us_gov },
    .{ "us-gov-west-1", &prtn_aws_us_gov },
    .{ "aws-iso-global", &prtn_aws_iso },
    .{ "us-iso-east-1", &prtn_aws_iso },
    .{ "us-iso-west-1", &prtn_aws_iso },
    .{ "aws-iso-b-global", &prtn_aws_iso_b },
    .{ "us-isob-east-1", &prtn_aws_iso_b },
});

pub fn resolve(region: []const u8) ?*const Partition {
    if (partitions.get(region)) |p| return p;

    if (matchAws(region)) return &prtn_aws;

    if (matchAwsCn(region)) return &prtn_aws_cn;

    if (matchAwsUsGov(region)) return &prtn_aws_us_gov;

    if (matchAwsIso(region)) return &prtn_aws_iso;

    if (matchAwsIsoB(region)) return &prtn_aws_iso_b;

    if (matchAwsIsoE(region)) return &prtn_aws_iso_e;

    if (matchAwsIsoF(region)) return &prtn_aws_iso_f;

    return &prtn_aws;
}

fn matchAny(rest: *[]const u8, values: anytype) bool {
    const set = std.StaticStringMap(void).initComptime(values);

    const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len;

    if (!set.has(rest.*[0..i])) return false;

    rest.* = rest.*[i..rest.len];

    return true;
}

fn matchWord(rest: *[]const u8) bool {
    const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len;

    for (rest.*[0..i]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;

    rest.* = rest.*[i..rest.len];

    return true;
}

fn matchNumber(rest: *[]const u8) bool {
    const i = std.mem.indexOfScalar(u8, rest.*, '-') orelse rest.len;

    for (rest.*[0..i]) |c| if (!std.ascii.isDigit(c)) return false;

    rest.* = rest.*[i..rest.len];

    return true;
}

fn matchString(rest: *[]const u8, str: []const u8) bool {
    if (!std.mem.startsWith(u8, rest.*, str)) return false;

    rest.* = rest.*[str.len..rest.len];

    return true;
}

fn matchDash(rest: *[]const u8) bool {
    if (rest.len == 0 or rest.*[0] != '-') return false;

    rest.* = rest.*[1..rest.len];

    return true;
}
