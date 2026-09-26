const std = @import("std");
const z = @import("../root.zig");

pub const LFO = struct {
    ctx: *const z.GraphContext,
    id: []const u8 = "wobb",
    base_pitch: z.Signal = .{ .static = 440.0 },
    frequency: z.Signal = .{ .static = 10.0 },

    amp: z.Signal = .{ .static = 10.0 },
    out: z.Signal = .{ .static = 0.0 },
    phase: f32 = 0,

    pub const ins = .{ .base_pitch, .frequency, .amp };
    pub const outs = .{.out};

    pub fn process(ptr: *anyopaque) void {
        var w: *LFO = @ptrCast(@alignCast(ptr));

        const result = w.base_pitch.get() + w.amp.get() * std.math.sin(w.phase);

        w.phase += std.math.tau * w.frequency.get() * w.ctx.inv_sample_rate;

        while (w.phase >= std.math.tau) {
            w.phase -= std.math.tau;
        }

        w.out.set(result);
    }

    pub fn node(ptr: *LFO) z.Node {
        return z.Node.init(ptr, LFO);
    }
};
