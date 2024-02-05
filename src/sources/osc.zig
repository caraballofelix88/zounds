//TODO: try building iterators to send to audio render func?
// is there a way to make them stateful?

const std = @import("std");
const sources = @import("main.zig");

// TODO: provide a sample generator function?
// TODO:(needless optimization) you only really need to hold onto samples for [0, pi/2] for cyclic waves,
// the rest of the waveform can be derived from that first chunk
pub fn Wavetable(comptime num_buckets: comptime_int) [num_buckets]f32 {
    var buf: [num_buckets]f32 = undefined;

    // builds sine wavetable
    @setEvalBranchQuota(num_buckets * 2 + 1);
    comptime {
        inline for (0..num_buckets) |i| {
            const ind: f32 = @floatFromInt(i);
            const buckets: f32 = @floatFromInt(num_buckets);
            const phase: f32 = ind / buckets * std.math.tau;
            buf[i] = std.math.sin(phase);
        }
    }

    return buf;
}

// lil sine wavetable
pub const waveTable = Wavetable(64);
// bigger sine wavetable
pub const bigWave = Wavetable(512);

// TODO: theres a builtin lerp already, lol
pub fn lerp(table: []f32, phase: f32) f32 {
    const lowInd: usize = @intFromFloat(@floor(phase));
    const highInd: usize = @intFromFloat(@ceil(phase));
    const wrappedInd: usize = @mod(highInd, table.len);

    const distance: f32 = @rem(phase, 1);

    return (1 - distance) * table[lowInd] + distance * table[wrappedInd];
}

// TODO: assumes f32 output format
pub const WavetableIterator = struct {
    phase: f32 = 0,
    wavetable: []f32,
    pitch: f32,
    sample_rate: f32,
    buf: [4]u8 = undefined,
    // ^ Honestly, feels weird to just point to a single sample by ref? this will surely break eventually
    withLerp: bool = false,

    const Self = @This();

    pub fn next(self: *Self) ?[]u8 {
        const len: f32 = @floatFromInt(self.wavetable.len);
        const ind: usize = @intFromFloat(@floor(@mod(self.phase, len)));

        var result: f32 = undefined;
        if (self.withLerp) {
            result = lerp(self.wavetable, self.phase);
        } else {
            result = self.wavetable[ind];
        }
        self.buf = @bitCast(result);
        self.phase += @as(f32, @floatFromInt(self.wavetable.len)) * self.pitch / self.sample_rate;
        while (self.phase >= len) {
            self.phase -= len;
        }

        return self.buf[0..];
    }

    pub fn hasNext(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        var iter: *Self = @ptrCast(@alignCast(ptr));
        return iter.next();
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        var iter: *Self = @ptrCast(@alignCast(ptr));
        return iter.hasNext();
    }

    pub fn source(self: *Self) sources.AudioSource {
        return .{
            .ptr = self,
            .hasNextFn = hasNextFn,
            .nextFn = nextFn,
        };
    }

    pub fn setPitch(self: *Self, val: f32) void {
        self.pitch = val;
    }
};
