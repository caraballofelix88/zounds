const std = @import("std");

const sources = @import("../sources/main.zig");

// TODO: needs to know sample format, or at least confirm the sample formats are the sample

// TODO: how to add arbitrary number of signals together?
pub const Adder = struct {
    sourceA: sources.AudioSource,
    sourceB: sources.AudioSource,

    buf: [4]u8 = undefined,

    pub fn next(self: *anyopaque) ?[]u8 {
        const adder: *Adder = @ptrCast(@alignCast(self));

        var a = adder.sourceA;
        var b = adder.sourceB;

        const aNext = a.next().?;
        const bNext = b.next().?;

        const sample_size = 4;

        const aFloat: f32 = std.mem.bytesAsValue(f32, aNext[0..sample_size]).*;
        const bFloat: f32 = std.mem.bytesAsValue(f32, bNext[0..sample_size]).*;

        const sum: f32 = (aFloat + bFloat) / 2;
        adder.buf = @bitCast(sum);

        return adder.buf[0..];
    }

    pub fn hasNext(self: *anyopaque) bool {
        const adder: *Adder = @ptrCast(@alignCast(self));

        return adder.sourceA.hasNext() and adder.sourceB.hasNext();
    }

    pub fn source(self: *Adder) sources.AudioSource {
        return .{ .ptr = self, .nextFn = next, .hasNextFn = hasNext };
    }
};
