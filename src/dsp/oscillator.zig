const std = @import("std");
const signals = @import("../signals.zig");
const wavegen = @import("../wavegen.zig");

pub const Oscillator = struct {
    ctx: signals.GraphContext,
    id: []const u8 = "oscillator",
    wavetable: []const f32 = &wavegen.sine_wave,
    pitch: signals.Signal = .{ .static = 440.0 },
    amp: signals.Signal = .{ .static = 1.0 },
    out: signals.Signal = .{ .static = 0.0 },
    phase: f32 = 0.0,

    pub const ins = [_]std.meta.FieldEnum(Oscillator){ .pitch, .amp };
    pub const outs = [_]std.meta.FieldEnum(Oscillator){.out};

    pub fn process(ptr: *anyopaque) void {
        const n: *Oscillator = @ptrCast(@alignCast(ptr));

        // TODO: clamps on inputs, what if this is -3billion

        const len: f32 = @floatFromInt(n.wavetable.len);

        const lowInd: usize = @intFromFloat(@floor(n.phase));
        const highInd: usize = @intFromFloat(@mod(@ceil(n.phase), len));

        const fractional_distance: f32 = @rem(n.phase, 1);

        const result: f32 = std.math.lerp(n.wavetable[lowInd], n.wavetable[highInd], fractional_distance) * n.amp.get();

        n.phase += len * n.pitch.get() * n.ctx.inv_sample_rate;
        while (n.phase >= len) {
            n.phase -= len;
        }

        // store latest result
        n.out.set(result);
    }

    pub fn node(self: *Oscillator) signals.Node {
        return signals.Node.init(self, Oscillator);
    }
};
