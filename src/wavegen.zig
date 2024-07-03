const std = @import("std");

pub const Waveform = enum {
    square,
    sine,
    wobble,
    noise,
};

fn square(comptime phase: comptime_float) f32 {
    if (phase >= std.math.pi) {
        return -1.0;
    }
    return 1.0;
}

fn wobble(comptime phase: comptime_float, num_harmonics: comptime_int) f32 {
    const half: f32 = 0.5;
    var result: f32 = 0.0;

    for (1..num_harmonics) |i| {
        const h = @as(comptime_float, i);
        result += std.math.pow(f32, half, h) * std.math.sin(phase * h);
    }
    return result;
}

fn sine(comptime phase: comptime_float) f32 {
    return std.math.sin(phase);
}

fn noise(rand: std.rand.Random) f32 {
    return rand.float(f32) * 2.0 - 1.0;
}

pub fn Wavetable(comptime num_buckets: comptime_int, comptime waveform: Waveform) [num_buckets]f32 {
    var buf: [num_buckets]f32 = undefined;

    const num_harmonics = 9;
    var prng = std.rand.DefaultPrng.init(0);

    // is maxing out eval branches like this clumsy?
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        for (0..num_buckets) |i| {
            const ind: f32 = @floatFromInt(i);
            const buckets: f32 = @floatFromInt(num_buckets);
            const phase: f32 = ind / buckets * std.math.tau;

            switch (waveform) {
                .sine => {
                    buf[i] = sine(phase);
                },
                .wobble => {
                    buf[i] = wobble(phase, num_harmonics);
                },
                .square => {
                    buf[i] = square(phase);
                },
                .noise => {
                    buf[i] = noise(prng.random());
                },
            }
        }
    }

    return buf;
}

pub const wobble_wave = Wavetable(512, .wobble);
pub const hiss = Wavetable(512, .noise);
pub const sine_wave = Wavetable(1024, .sine);
