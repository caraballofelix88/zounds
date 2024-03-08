const std = @import("std");
const testing = std.testing;

// TODO: Input Signals vs Audio Sources? They should just be the same, yea?

// TODO: tagged union?
const RampTypeTag = enum { linear, exp };

const RampType = union(RampTypeTag) {
    linear: void,
    exp: f32,
};

const Duration = union { millis: u32, samples: u32, seconds: f32 };

const Args = struct { from: f32, to: f32, duration: Duration, sample_rate: u32, ramp_type: RampType };

// TODO: Try stateless ramp struct?
const Ramp = struct {
    ramp_type: RampType,
    from: f32,
    to: f32,
    curr_value: f32,
    decay_scale: f32 = 1.0,
    duration_millis: u32,
    duration_samples: u32,
    sample_rate: u32,
    // TODO: refactor? this counter is the only real state
    counter: u32,

    // TODO: check Duration union for non-milli values
    // TODO: what about a at(sample_num) function, that eliminates the need for an internal iterator?
    fn init(args: Args) Ramp {
        const f_millis: f32 = @floatFromInt(args.duration.millis);
        const f_rate: f32 = @floatFromInt(args.sample_rate);
        const dur_samples: f32 = @floor(f_rate * f_millis / 1000.0);

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
            .duration_millis = args.duration.millis,
            .duration_samples = @intFromFloat(dur_samples),
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
        .duration = .{ .millis = 10 },
    }),
    Ramp.init(.{
        .from = 1.0,
        .to = 0.0,
        .ramp_type = .{ .exp = 0.95 },
        .sample_rate = 44_100,
        .duration = .{ .millis = 4000 },
    }),
};

// Envelope, vs EnvelopeState?
// Maintain a single Ramp instance, and cycle through

pub const Envelope = struct {
    ramps: []Ramp,
    ramp_index: usize = 0,
    should_loop: bool = true,

    pub fn next(e: *Envelope) f32 {
        if (!e.hasNext()) {
            return 0.0;
        }
        var ramp = &e.ramps[e.ramp_index];

        const result = ramp.next();

        if (!ramp.hasNext()) {
            std.debug.print("Increment ramp: {}", .{e.ramp_index});
            e.ramp_index += 1;
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
        for (e.ramps) |*ramp| {
            // TODO: this is not a good look, fix ramp state
            @constCast(ramp).reset();
        }
        e.ramp_index = 0;
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

test "Envelope" {}
