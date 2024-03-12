const std = @import("std");

const main = @import("main.zig");
const sources = @import("sources/main.zig");

// resources:
// - https://www.w3.org/TR/audio-eq-cookbook/
// - https://www.dspguide.com/ch19.htm

pub const FilterType = enum {
    low_pass,
    high_pass,
};

// TODO: normalize zero coefficients?
pub fn getFilterCoefficients(filter_type: FilterType, sample_freq: u32, cutoff_freq: u32, q: f32) [2][3]f32 {
    const f_s: f32 = @floatFromInt(sample_freq);
    const f_0: f32 = @floatFromInt(cutoff_freq);

    var a: [3]f32 = undefined;
    var b: [3]f32 = undefined;

    const w = std.math.tau * f_0 / f_s;

    const sin_w = @sin(w);
    const cos_w = @cos(w);

    const alpha = sin_w / 2 * q;

    switch (filter_type) {
        .low_pass => {
            const a_0 = 1 + alpha;
            const b_0 = (1 - cos_w) / 2;

            a[0] = a_0;
            a[1] = (-2 * cos_w);
            a[2] = (1 - alpha);

            b[0] = b_0;
            b[1] = (1 - cos_w);
            b[2] = ((1 - cos_w) / 2);
        },
        .high_pass => {
            a[0] = 1 + alpha;
            a[1] = -2 * cos_w;
            a[2] = 1 - alpha;

            b[0] = (1 + cos_w) / 2;
            b[1] = -1 * (1 + cos_w);
            b[2] = (1 + cos_w) / 2;
        },
    }
    return .{ a, b };
}

// Recursive biquad filter
pub const Filter = struct {
    in_source: sources.AudioSource,
    prev_x: [2]f32 = std.mem.zeroes([2]f32),
    prev_y: [2]f32 = std.mem.zeroes([2]f32),
    buf: [4]u8 = undefined,
    filter_type: FilterType = .low_pass,
    sample_rate: u32 = 44_100,
    cutoff_freq: u32 = 1000,
    q: f32 = 0.707, // -3dB

    pub fn init(in_source: sources.AudioSource) Filter {
        return .{ .in_source = in_source };
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const f: *Filter = @ptrCast(@alignCast(ptr));

        const next_sample_raw: ?[]u8 = f.in_source.next();
        const next_sample: f32 = std.mem.bytesAsValue(f32, next_sample_raw.?).*;

        // TODO: pass in sample rate
        const coeffs = getFilterCoefficients(f.filter_type, f.sample_rate, f.cutoff_freq, f.q);

        const result = f.calcResult(next_sample, coeffs[0], coeffs[1]);

        // track latest sample in/out
        f.prev_x[1] = f.prev_x[0];
        f.prev_y[1] = f.prev_y[0];

        f.prev_x[0] = next_sample;
        f.prev_y[0] = result;

        f.buf = @bitCast(result);
        return f.buf[0..];
    }

    // "Direct Form 1"
    fn calcResult(f: Filter, x: f32, a: [3]f32, b: [3]f32) f32 {
        return (b[0] / a[0]) * x + (b[1] / a[0]) * f.prev_x[0] + (b[2] / a[0]) * f.prev_x[1] - (a[1] / a[0]) * f.prev_y[0] - (a[2] / a[0]) * f.prev_y[1];
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        const f: *Filter = @ptrCast(ptr);
        return f.source().hasNext();
    }

    pub fn source(f: *Filter) sources.AudioSource {
        return .{ .ptr = f, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};
