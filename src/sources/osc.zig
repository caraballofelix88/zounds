const std = @import("std");
const sources = @import("main.zig");
const envelope = @import("../envelope.zig");

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

pub const bigWave = Wavetable(512, .wobble);
pub const hiss = Wavetable(512, .noise);

// TODO: assumes f32 output format
pub const WavetableIterator = struct {
    phase: f32 = 0,
    wavetable: []f32,
    pitch: f32,
    pitch_generator: ?*envelope.Envelope = null, // Signal(f32)???
    amp_generator: ?*envelope.Envelope = null,
    sample_rate: f32,
    buf: [4]u8 = undefined,
    //TODO: ^ Honestly, feels weird to just point to a single sample by ref? this will surely break eventually

    pub fn next(self: *WavetableIterator) ?[]u8 {
        const len: f32 = @floatFromInt(self.wavetable.len);

        var pitch: f32 = 0;
        if (self.pitch_generator) |gen| {
            pitch = gen.next();
        } else {
            pitch = self.pitch;
        }

        var amplitude: f32 = 1.0;
        if (self.amp_generator) |gen| {
            amplitude = gen.next();
        }

        const lowInd: usize = @intFromFloat(@floor(self.phase));
        const highInd: usize = @intFromFloat(@mod(@ceil(self.phase), len));

        const distance: f32 = @rem(self.phase, 1);

        const result: f32 = std.math.lerp(self.wavetable[lowInd], self.wavetable[highInd], distance) * amplitude;

        self.buf = @bitCast(result);
        self.phase += @as(f32, @floatFromInt(self.wavetable.len)) * pitch / self.sample_rate;

        while (self.phase >= len) {
            self.phase -= len;
        }

        return self.buf[0..];
    }

    pub fn hasNext(self: *WavetableIterator) bool {
        _ = self;
        return true;
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        var iter: *WavetableIterator = @ptrCast(@alignCast(ptr));
        return iter.next();
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        var iter: *WavetableIterator = @ptrCast(@alignCast(ptr));
        return iter.hasNext();
    }

    pub fn source(self: *WavetableIterator) sources.AudioSource {
        return .{
            .ptr = self,
            .hasNextFn = hasNextFn,
            .nextFn = nextFn,
        };
    }

    pub fn setPitch(self: *WavetableIterator, val: f32) void {
        self.pitch = val;
    }
};
