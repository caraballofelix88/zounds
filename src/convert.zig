const std = @import("std");
const testing = std.testing;

// shoutouts to the mach folks
pub fn convert(comptime SourceType: type, comptime DestType: type, source: []SourceType, dest: []DestType) void {
    // lets start with a single concrete case for now
    // std.debug.assert(SourceType == u16 and DestType == f32)

    //TODO: assert source data will fit in dest

    switch (DestType) {
        f32 => {
            switch (SourceType) {
                u16 => {
                    for (source, dest) |*src_sample, *dst_sample| {
                        const half = (std.math.maxInt(SourceType) + 1) / 2;
                        dst_sample.* = (@as(DestType, @floatFromInt(src_sample.*)) - half) * 1.0 / half;
                    }
                },
                i16 => {
                    const max: comptime_float = std.math.maxInt(SourceType) + 1;
                    const inv_max = 1.0 / max;
                    for (source, dest) |*src_sample, *dst_sample| {
                        dst_sample.* = @as(DestType, @floatFromInt(src_sample.*)) * inv_max;
                    }
                },
                f32 => { // just copy the data over
                    @memcpy(dest, source);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "convert.i16 -> f32" {
    const epsilon = 0.001;
    var source: [3]i16 = .{ 0, 32767, -32768 };
    const expected: [3]f32 = .{ 0.0, 1.0, -1.0 };
    var dest: [3]f32 = undefined;

    convert(i16, f32, &source, &dest);

    for (expected, dest) |a, b| {
        try testing.expectApproxEqAbs(a, b, epsilon);
    }
}

test "convert.u16 -> f32" {
    const epsilon = 0.001;
    var source: [3]u16 = .{ 0, 32_768, 65_535 };
    const expected: [3]f32 = .{ -1.0, 0.0, 1.0 };
    var dest: [3]f32 = undefined;

    convert(u16, f32, &source, &dest);

    for (expected, dest) |a, b| {
        try testing.expectApproxEqAbs(a, b, epsilon);
    }
}
