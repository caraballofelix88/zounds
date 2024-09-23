const std = @import("std");
const signals = @import("signals.zig");
const testing = std.testing;

const RampTypeTag = enum { linear, exp };
const RampType = union(RampTypeTag) {
    linear: void,
    exp: f32,
};

// NOTE: using @floor will result in some inexact values. Keep an eye on this
const DurationTags = enum { millis, seconds, samples };
const Duration = union(DurationTags) {
    millis: u32,
    seconds: f32,
    samples: u32,

    pub fn in_millis(d: Duration, sample_rate: u32) u32 {
        return switch (d) {
            .millis => |m| m,
            .seconds => |s| @intFromFloat(@floor(s * 1000.0)),
            .samples => |s| @intFromFloat(@floor(@as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(sample_rate)) * 1000.0)),
        };
    }

    pub fn in_seconds(d: Duration, sample_rate: u32) f32 {
        return switch (d) {
            .millis => |m| @as(f32, @floatFromInt(m / 1000)),
            .seconds => |s| s,
            .samples => |s| @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(sample_rate)),
        };
    }

    pub fn in_samples(d: Duration, sample_rate: u32) u32 {
        return switch (d) {
            .millis => |m| m * sample_rate / 1000,
            .seconds => |s| @intFromFloat(@floor(@as(f32, @floatFromInt(sample_rate)) * s)),
            .samples => |s| s,
        };
    }
};

test "Duration" {
    const sample_rate: u32 = 44_100;
    const secs: Duration = .{ .seconds = 1.0 };
    try testing.expectEqual(secs.in_millis(sample_rate), 1000);
    try testing.expectEqual(secs.in_samples(sample_rate), 44_100);
    try testing.expectEqual(secs.in_seconds(sample_rate), 1.0);

    const millis: Duration = .{ .millis = 1000 };
    try testing.expectEqual(millis.in_millis(sample_rate), 1000);
    try testing.expectEqual(millis.in_samples(sample_rate), 44_100);
    try testing.expectEqual(millis.in_seconds(sample_rate), 1.0);

    const samples: Duration = .{ .samples = 44_100 };
    try testing.expectEqual(samples.in_millis(sample_rate), 1000);
    try testing.expectEqual(samples.in_samples(sample_rate), 44_100);
    try testing.expectEqual(samples.in_seconds(sample_rate), 1.0);
}

pub const Ramp = struct {
    from: f32,
    to: f32,
    duration: Duration,
    sample_rate: u32,
    ramp_type: RampType,

    pub fn at(r: Ramp, index: usize) f32 {
        if (index >= r.duration_samples()) {
            return r.to;
        }

        if (index <= 0) {
            return r.from;
        }

        if (r.from == r.to) {
            return r.from;
        }

        const t: f32 = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(r.duration_samples()));

        return switch (r.ramp_type) {
            .linear => std.math.lerp(r.from, r.to, t),
            // TODO: fix exp asymptote math, its totally wrong
            .exp => |alpha| blk: {
                const diff = if (r.from > r.to) r.from - r.to else r.to - r.from;
                _ = diff;

                const decay_scale = std.math.pow(f32, 1.0 - alpha, @as(f32, @floatFromInt(r.sample_rate)));

                break :blk r.from * std.math.pow(f32, decay_scale, @as(f32, @floatFromInt(index)));
            },
        };
    }

    pub fn duration_samples(r: Ramp) u32 {
        return r.duration.in_samples(r.sample_rate);
    }
};

test "Ramp" {
    var args: Ramp = .{
        .from = 1.0,
        .to = 10.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 100 },
    };

    try testing.expectEqual(1.0, args.at(0));
    try testing.expectEqual(10.0, args.at(4410));
    try testing.expectEqual(10.0, args.at(10_000));

    args.from = 3.5;
    try testing.expectEqual(3.5, args.at(0));
}

pub var wail: [2]Ramp = .{
    .{
        .from = 300.0,
        .to = 1500.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 2000 },
    },
    .{
        .from = 1500.0,
        .to = 300.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 10 },
    },
};

pub const percussion: [2]Ramp = .{
    .{
        .from = 0.0,
        .to = 1.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 5 },
    },
    .{
        .from = 1.0,
        .to = 0.0,
        .ramp_type = .{ .exp = 0.99 },
        .sample_rate = 44_100,
        .duration = .{ .millis = 4000 },
    },
};

// ADSR state?
pub const adsr: [4]Ramp = .{
    .{ // attack
        .from = 0.0,
        .to = 1.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 0.05 },
    },
    .{ // decay
        .from = 1.0,
        .to = 0.7,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 0.2 },
    },
    .{ // sustain
        .from = 0.7,
        .to = 0.5,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 1.0 },
    },

    .{ // release
        .from = 0.5,
        .to = 0.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 0.3 },
    },
};

pub const ADSRConfig = struct {
    amplitude: f32 = 1.0,
    sample_rate: u32 = 44_100,
    attack_duration: Duration = .{ .seconds = 0.05 },
    decay_duration: Duration = .{ .seconds = 0.2 },
    sustain_duration: Duration = .{ .seconds = 1 },
    release_duration: Duration = .{ .seconds = 0.3 },
};
pub fn generateADSR(config: ADSRConfig) [4]Ramp {
    return .{
        .{ // attack
            .from = 0.0,
            .to = config.amplitude,
            .ramp_type = .linear,
            .sample_rate = config.sample_rate,
            .duration = config.attack_duration,
        },
        .{ // decay
            .from = config.amplitude,
            .to = 0.7 * config.amplitude,
            .ramp_type = .linear,
            .sample_rate = config.sample_rate,
            .duration = config.decay_duration,
        },
        .{ // sustain
            .from = 0.7 * config.amplitude,
            .to = 0.5 * config.amplitude,
            .ramp_type = .linear,
            .sample_rate = config.sample_rate,
            .duration = config.sustain_duration,
        },

        .{ // release
            .from = 0.5 * config.amplitude,
            .to = 0.0,
            .ramp_type = .linear,
            .sample_rate = config.sample_rate,
            .duration = config.release_duration,
        },
    };
}

// TODO: create a method to start at some arbitrary point anywhere within envelope duration? Using context?
// TODO: how do we make stateless, for reuse across multiple oscillators or MIDI voices?
//NOTE: stateless kind of a hefty tradeoff, maybe....
// TODO: rename to ADSR
pub const Envelope = struct {
    ramps: []const Ramp,
    trigger: signals.Signal,
    active: bool = false,
    prev_trigger_state: bool = false,
    ramp_index: usize = 0,
    curr_ramp: Ramp,
    sample_index: usize = 0,
    latest_value: f32 = 0.0,

    pub fn init(ramps: []const Ramp, trigger: ?signals.Signal) Envelope {
        return .{
            .ramps = ramps,
            .trigger = trigger orelse .{ .static = 0.0 },
            .curr_ramp = ramps[0],
        };
    }

    pub fn nextFn(ptr: *anyopaque) f32 {
        var e: *Envelope = @ptrCast(@alignCast(ptr));

        if (e.trigger.get() != 0.0) {
            if (!e.prev_trigger_state) {
                e.attack();
            }
            e.prev_trigger_state = true;
        } else {
            if (e.prev_trigger_state) {
                e.release();
                e.prev_trigger_state = false;
            }
        }

        if (!e.hasNext()) {
            return e.latest_value;
        }

        const result = e.curr_ramp.at(e.sample_index);

        e.latest_value = result;
        e.sample_index += 1;

        // handle reaching end of current ramp
        if (e.sample_index >= e.curr_ramp.duration_samples()) {
            e.ramp_index += 1;

            if (e.hasNext()) {
                e.curr_ramp = e.ramps[e.ramp_index];
                e.curr_ramp.from = e.latest_value;
                e.sample_index = 0;
            } else {
                e.active = false;
            }
        }

        return result;
    }

    fn hasNext(e: Envelope) bool {
        return e.active and e.ramp_index < e.ramps.len;
    }

    pub fn attack(e: *Envelope) void {
        e.active = true;
        e.ramp_index = 0;
        e.sample_index = 0;
        e.curr_ramp = e.ramps[0];
        e.curr_ramp.from = e.latest_value;
    }

    pub fn release(e: *Envelope) void {
        e.ramp_index = 3;
        e.sample_index = 0;
        e.curr_ramp = e.ramps[3];
        e.curr_ramp.from = e.latest_value;
    }

    pub fn node(e: *Envelope) signals.Node(f32) {
        return .{ .ptr = e, .nextFn = nextFn };
    }
};

test "Envelope" {
    var ramps: [4]Ramp = .{
        .{
            .from = 0.0,
            .to = 10.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .samples = 5 },
        },
        .{
            .from = 10.0,
            .to = 8.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .samples = 2 },
        },
        .{
            .from = 8.0,
            .to = 8.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .samples = 5 },
        },
        .{
            .from = 1500.0,
            .to = 300.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .samples = 10 },
        },
    };

    var trigger: bool = false;
    var e = Envelope.init(&ramps, null);

    // test default value on inactive envelope
    try testing.expectEqual(0.0, Envelope.nextFn(&e));
    try testing.expectEqual(0.0, Envelope.nextFn(&e));

    // attack
    trigger = true;
    try testing.expectEqual(0.0, Envelope.nextFn(&e));
    try testing.expectEqual(2.0, Envelope.nextFn(&e));

    // TODO:
    // Test shift to inactive state
    // Test sequential transition between ramps
    // test release retains latest value
    // test attack retains latest value
}
