const std = @import("std");
const z = @import("../root");
const clock = @import("../clock.zig");
const wavegen = @import("../wavegen.zig");

pub const Click = struct {
    ctx: *const z.GraphContext,
    id: []const u8 = "click",
    bpm: z.Signal = .{ .static = 120.0 },

    out: z.Signal = .{ .static = 0.0 },

    pub const ins = .{.bpm};
    pub const outs = .{.out};

    pub fn process(ptr: *anyopaque) void {
        var c: *Click = @ptrCast(@alignCast(ptr));

        const beat_duration = clock.NoteDuration.sampleInterval(clock.NoteDuration.quarter, c.ctx.sample_rate, @intFromFloat(c.bpm.get()));
        const click_duration = beat_duration / 4;

        const in_sample_modulo = @mod(c.ctx.ticks(), beat_duration) <= click_duration;

        if (in_sample_modulo) {
            c.out.set(1.0);
        } else {
            c.out.set(0.0);
        }
    }

    pub fn node(ptr: *Click) z.Node {
        return z.Node.init(ptr, Click);
    }
};
