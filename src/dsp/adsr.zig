const std = @import("std");
const signals = @import("../signals.zig");
const env = @import("../envelope.zig");

// TODO: detail params for adjusting ramps
pub const ADSROptions = struct {};
pub fn ADSR(opts: ADSROptions) type {
    _ = opts;

    const adsr_ramps: [4]env.Ramp = .{
        .{ // attack
            .from = 0.0,
            .to = 1.0,
            .ramp_type = .linear,
            .sample_rate = 22_050,
            .duration = .{ .seconds = 0.05 },
        },
        .{ // decay
            .from = 1.0,
            .to = 0.7,
            .ramp_type = .linear,
            .sample_rate = 22_050,
            .duration = .{ .seconds = 0.2 },
        },
        .{ // sustain
            .from = 0.7,
            .to = 0.5,
            .ramp_type = .linear,
            .sample_rate = 22_050,
            .duration = .{ .seconds = 1.0 },
        },

        .{ // release
            .from = 0.5,
            .to = 0.0,
            .ramp_type = .linear,
            .sample_rate = 22_050,
            .duration = .{ .seconds = 0.3 },
        },
    };

    return struct {
        const State = enum(u8) { attack = 0, sustain = 1, decay = 2, release = 3, off = 4 };

        const Self = @This();

        ctx: *signals.Context,
        id: []const u8 = "adsr",
        state: Self.State = .off,
        trigger: signals.Signal = .{ .static = 0.0 },
        prev_trigger: f32 = 0.0,
        out: signals.Signal = .{ .static = 0.0 },
        attack_ts: u64 = 0,
        release_ts: u64 = 0,
        prev_val: f32 = 0.0,
        ramps: [4]env.Ramp = adsr_ramps,
        hold_duration: u64 = 0,

        pub const ins = .{.trigger};
        pub const outs = .{.out};

        pub fn process(ptr: *anyopaque) void {
            var adsr: *Self = @ptrCast(@alignCast(ptr));

            // update state
            if (adsr.trigger.get() > adsr.prev_trigger) {
                adsr.state = .attack;
                adsr.attack_ts = adsr.ctx.ticks;
                adsr.ramps[0].from = adsr.prev_val;
                adsr.hold_duration = 0;
            }

            if (adsr.trigger.get() < adsr.prev_trigger) {
                adsr.state = .release;
                adsr.release_ts = adsr.ctx.ticks;
                adsr.ramps[3].from = adsr.prev_val;
                adsr.hold_duration = 0;
            }

            if (adsr.state == .off) {
                return;
            }

            var curr_ramp = adsr.ramps[@intFromEnum(adsr.state)];
            const ramp_duration = curr_ramp.duration_samples();

            const val = curr_ramp.at(adsr.hold_duration);
            adsr.hold_duration += 1;

            if (adsr.hold_duration >= ramp_duration) {
                const next_state: Self.State = @enumFromInt(@intFromEnum(adsr.state) + 1);

                adsr.state = next_state;

                if (next_state != .off) {
                    adsr.ramps[@intFromEnum(adsr.state)].from = adsr.prev_val;
                    adsr.hold_duration = 0;
                }
            }

            adsr.prev_trigger = adsr.trigger.get();
            adsr.prev_val = val;
            adsr.out.set(val);
        }

        pub fn node(ptr: *Self) signals.Node {
            return signals.Node.init(ptr, Self);
        }
    };
}
