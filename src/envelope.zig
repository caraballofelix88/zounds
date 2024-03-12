const std = @import("std");
const testing = std.testing;

// TODO: Input Signals vs Audio Sources? They should just be the same, yea?

const RampTypeTag = enum { linear, exp };
const RampType = union(RampTypeTag) {
    linear: void,
    exp: f32,
};

// TODO: Add sample_rate comptime?
// TODO: @floor might result in some weird values. Keep an eye on this
// TODO: Is this an abuse of tagged unions? NAH, PROLLY NOT
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

const Ramp = struct {
    from: f32,
    to: f32,
    duration: Duration,
    sample_rate: u32,
    ramp_type: RampType,

    fn at(r: Ramp, index: usize) f32 {
        if (index >= r.duration_samples()) {
            return r.to;
        }

        if (index <= 0) {
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

    fn duration_samples(r: Ramp) u32 {
        return r.duration.in_samples(r.sample_rate);
    }
};

// TODO: Try stateless ramp struct?
test "Ramp" {
    const args: Ramp = .{
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

// TODO: construct ADSR envelope UI?
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

// Maintains transition state between Ramps.
// TODO: create a method to start at some arbitrary point anywhere within envelope duration?
// TODO: add state machine logic
pub const Envelope = struct {
    ramps: []const Ramp,
    ramp_index: usize = 0,
    curr_ramp: Ramp,
    sample_index: usize = 0,
    latest_value: f32 = 0.0,
    should_loop: bool = false,

    pub fn init(ramps: []const Ramp, should_loop: bool) Envelope {
        return .{
            .ramps = ramps,
            .curr_ramp = ramps[0],
            .should_loop = should_loop,
        };
    }

    pub fn next(e: *Envelope) f32 {
        if (!e.hasNext()) {
            return e.latest_value; // e.curr_ramp.at(e.sample_index);
        }

        const result = e.curr_ramp.at(e.sample_index);

        e.latest_value = result;
        e.sample_index += 1;

        // handle reaching end of current ramp
        if (e.sample_index >= e.curr_ramp.duration_samples()) {
            std.debug.print("Increment ramp: {}\n", .{e.ramp_index});
            e.ramp_index += 1;

            if (e.hasNext()) {
                e.curr_ramp = e.ramps[e.ramp_index];
                e.curr_ramp.from = e.latest_value;
                e.sample_index = 0;
            } else {
                // if should loop, reset to
                if (e.should_loop) {
                    e.ramp_index = 0;
                    e.curr_ramp = e.ramps[0];
                    e.sample_index = 0;
                    e.latest_value = e.ramps[0].from;
                }
            }
        }

        return result;
    }

    pub fn hasNext(e: Envelope) bool {
        return e.ramp_index < e.ramps.len;
    }

    pub fn attack(e: *Envelope) void {
        if (e.ramps.len != 4) {
            return;
        }

        std.debug.print("Attack\n", .{});
        e.ramp_index = 0;
        e.sample_index = 0;
        e.curr_ramp = e.ramps[0];
        e.curr_ramp.from = e.latest_value;
    }

    pub fn release(e: *Envelope) void {
        if (e.ramps.len != 4) {
            return;
        }

        std.debug.print("Release\n", .{});
        e.ramp_index = 3;
        e.sample_index = 0;
        e.curr_ramp = e.ramps[3];
        e.curr_ramp.from = e.latest_value;
    }
};

test "Envelope" {
    var e = Envelope.init(&wail, false);

    try testing.expectEqual(e.next(), 300.0);
    try testing.expectEqual(e.sample_index, 1);
}
