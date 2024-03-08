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

const RampArgs = struct { from: f32, to: f32, duration: Duration, sample_rate: u32, ramp_type: RampType };

// TODO: Try stateless ramp struct?
const Ramp = struct {
    ramp_type: RampType,
    from: f32,
    to: f32,
    curr_value: f32,
    decay_scale: f32 = 1.0,
    duration_samples: u32,
    sample_rate: u32,
    // TODO: refactor? this counter is the only real state
    counter: u32,

    // TODO: what about a at(sample_num) function, that eliminates the need for an internal iterator?
    fn init(args: RampArgs) Ramp {
        const f_rate: f32 = @floatFromInt(args.sample_rate);
        var decay_scale: f32 = 1.0;

        switch (args.ramp_type) {
            .exp => |alpha| decay_scale = std.math.pow(f32, 1.0 - alpha, 1.0 / f_rate),
            else => {},
        }

        return .{
            .from = args.from,
            .to = args.to,
            .curr_value = args.from,
            .decay_scale = decay_scale,
            .duration_samples = args.duration.in_samples(args.sample_rate),
            .sample_rate = args.sample_rate,
            .ramp_type = args.ramp_type,
            .counter = 0,
        };
    }

    fn next(r: *Ramp) f32 {
        if (!r.hasNext()) {
            return r.to;
        }
        const f_duration: f32 = @floatFromInt(r.duration_samples);
        const f_counter: f32 = @floatFromInt(r.counter);
        const t: f32 = f_counter / f_duration;

        const result = switch (r.ramp_type) {
            .linear => std.math.lerp(r.from, r.to, t),
            .exp => r.curr_value * r.decay_scale,
        };

        // need to last val for exponential decay, or do we?
        r.curr_value = result;

        r.counter += 1;

        return result;
    }

    fn hasNext(r: Ramp) bool {
        return r.counter <= r.duration_samples;
    }

    fn reset(r: *Ramp) void {
        r.counter = 0;
        r.curr_value = r.from;
    }
};

var wail: [2]Ramp = .{
    Ramp.init(.{
        .from = 300.0,
        .to = 1500.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 2000 },
    }),
    Ramp.init(.{
        .from = 1500.0,
        .to = 300.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 10 },
    }),
};

const percussion: [2]Ramp = .{
    Ramp.init(.{
        .from = 0.0,
        .to = 1.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 1 },
    }),
    Ramp.init(.{
        .from = 1.0,
        .to = 0.0,
        .ramp_type = .{ .exp = 0.99 },
        .sample_rate = 44_100,
        .duration = .{ .millis = 4000 },
    }),
};

// TODO: construct ADSR envelope UI
// ADSR state?
pub const adsr: [4]Ramp = .{
    Ramp.init(.{ // attack
        .from = 0.0,
        .to = 1.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 0.1 },
    }),
    Ramp.init(.{ // decay
        .from = 1.0,
        .to = 0.7,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 0.3 },
    }),
    Ramp.init(.{ // sustain
        .from = 0.7,
        .to = 0.5,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 1.0 },
    }),

    Ramp.init(.{ // release
        .from = 0.5,
        .to = 0.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .seconds = 0.3 },
    }),
};

// Envelope, vs EnvelopeState?
// Maintain a single Ramp instance, and cycle through

pub const Envelope = struct {
    ramps: []Ramp,
    ramp_index: usize = 0,
    should_loop: bool = true,
    curr_value: f32 = 0.0,

    pub fn next(e: *Envelope) f32 {
        if (!e.hasNext()) {
            return 0.0;
        }
        var ramp = &e.ramps[e.ramp_index];

        const result = ramp.next();
        e.curr_value = result;

        if (!ramp.hasNext()) {
            std.debug.print("Increment ramp: {}\n", .{e.ramp_index});
            e.ramp_index += 1;

            if (e.hasNext()) {
                e.ramps[e.ramp_index].from = e.curr_value;
            }
        }

        if (!e.hasNext() and e.should_loop) {
            e.reset();
        }

        return result;
    }

    pub fn hasNext(e: Envelope) bool {
        return e.ramp_index < e.ramps.len;
    }

    pub fn reset(e: *Envelope) void {
        for (e.ramps, 0..) |*ramp, idx| {
            var r = ramp;
            if (idx == 0) {
                r.from = e.curr_value;
            }
            r.reset();
        }
        e.ramp_index = 0;
    }

    pub fn attack(e: *Envelope) void {
        if (e.ramps.len != 4) {
            return;
        }
        e.reset();
        e.ramps[0].from = e.curr_value;
        e.ramp_index = 0;
    }

    pub fn release(e: *Envelope) void {
        if (e.ramps.len != 4) {
            return;
        }

        e.reset();
        e.ramps[3].from = e.curr_value;
        e.ramp_index = 3;
    }
};

pub const env_wail = Envelope{
    .ramps = @constCast(&wail),
    .should_loop = true,
};

pub const env_percussion = Envelope{
    .ramps = @constCast(&percussion),
    .should_loop = false,
};

pub const env_adsr = Envelope{
    .ramps = @constCast(&adsr),
    .should_loop = false,
};

test "Ramp" {
    var ramp = Ramp.init(.{
        .from = 1.0,
        .to = 10.0,
        .ramp_type = .linear,
        .sample_rate = 44_100,
        .duration = .{ .millis = 100 },
    });

    try testing.expectEqual(ramp.duration_samples, 4410);
    try testing.expectEqual(ramp.next(), 1.0);
    try testing.expectEqual(ramp.hasNext(), true);

    ramp.counter = 4410;
    try testing.expectEqual(ramp.next(), 10.0);
    try testing.expectEqual(ramp.hasNext(), false);

    ramp.reset();
    try testing.expectEqual(ramp.counter, 0);
    try testing.expectEqual(ramp.hasNext(), true);
}
