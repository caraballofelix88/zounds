//TODO: try building iterators to send to audio render func?
// is there a way to make them stateful?

const std = @import("std");
const sources = @import("main.zig");

// TODO: provide a sample generator function?
// TODO:(needless optimization) you only really need to hold onto samples for [0, pi/2] for cyclic waves,
// the rest of the waveform can be derived from that first chunk

pub const Waveform = enum {
    square,
    sine,
    wobble,
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

pub fn Wavetable(comptime num_buckets: comptime_int, comptime waveform: Waveform) [num_buckets]f32 {
    var buf: [num_buckets]f32 = undefined;

    const num_harmonics = 9;

    @setEvalBranchQuota(num_buckets * 2 * num_harmonics * 2 + 1 * 3); // TODO: can just be some gigantic number, int.max or something
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
            }
        }
    }

    return buf;
}

pub const bigWave = Wavetable(512, .square);

// TODO: assumes f32 output format
pub const WavetableIterator = struct {
    phase: f32 = 0,
    wavetable: []f32,
    pitch: f32,
    sample_rate: f32,
    buf: [4]u8 = undefined,
    // ^ Honestly, feels weird to just point to a single sample by ref? this will surely break eventually

    pub fn next(self: *WavetableIterator) ?[]u8 {
        const len: f32 = @floatFromInt(self.wavetable.len);

        const lowInd: usize = @intFromFloat(@floor(self.phase));
        const highInd: usize = @intFromFloat(@mod(@ceil(self.phase), len));

        const distance: f32 = @rem(self.phase, 1);

        const result: f32 = std.math.lerp(self.wavetable[lowInd], self.wavetable[highInd], distance);

        self.buf = @bitCast(result);
        self.phase += @as(f32, @floatFromInt(self.wavetable.len)) * self.pitch / self.sample_rate;
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
