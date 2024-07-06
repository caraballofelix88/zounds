const std = @import("std");
const signals = @import("../signals.zig");
const wavegen = @import("../wavegen.zig");

pub const Oscillator = struct {
    ctx: *signals.Context,
    id: []const u8 = "oscillator",
    wavetable: []const f32 = &wavegen.sine_wave,
    pitch: ?signals.Signal = null,
    amp: ?signals.Signal = null,
    out: ?signals.Signal = null,
    phase: f32 = 0.0,

    pub const ins = [_]std.meta.FieldEnum(Oscillator){ .pitch, .amp };
    pub const outs = [_]std.meta.FieldEnum(Oscillator){.out};

    pub fn process(ptr: *anyopaque) void {
        const n: *Oscillator = @ptrCast(@alignCast(ptr));

        if (n.out == null) {
            std.debug.print("uh oh, no out for {s}\n", .{n.id});
            return;
        }

        // TODO: clamps on inputs, what if this is -3billion
        const pitch = blk: {
            if (n.pitch) |pitch| {
                break :blk pitch.get();
            }
            break :blk 440.0;
        };

        const amp = blk: {
            if (n.amp) |amp| {
                break :blk amp.get();
            }
            break :blk 0.5;
        };

        const len: f32 = @floatFromInt(n.wavetable.len);


        const lowInd: usize = @intFromFloat(@floor(n.phase));
        const highInd: usize = @intFromFloat(@mod(@ceil(n.phase), len));

        const fractional_distance: f32 = @rem(n.phase, 1);

        const result: f32 = std.math.lerp(n.wavetable[lowInd], n.wavetable[highInd], fractional_distance) * amp;

        n.phase += len * pitch * n.ctx.inv_sample_rate;
        while (n.phase >= len) {
            n.phase -= len;
        }

        // store latest result
        n.out.?.set(result);
    }

    pub fn node(self: *Oscillator) signals.Node {
        return signals.Node.init(self, Oscillator);
    }
};
