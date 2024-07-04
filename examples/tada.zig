const std = @import("std");
const zounds = @import("zounds");

const Signal = zounds.signals.Signal;
const Node = zounds.signals.Node;

// simple LFO
const Wobble = struct {
    ctx: *zounds.signals.Context,
    id: []const u8 = "wobb",
    base_pitch: ?Signal = .{ .static = 440.0 },
    frequency: ?Signal = .{ .static = 10.0 },

    amp: ?Signal = .{ .static = 10.0 },
    out: ?Signal = null,
    phase: f32 = 0,

    pub const ins = .{ .base_pitch, .frequency, .amp };
    pub const outs = .{.out};

    pub fn process(ptr: *anyopaque) void {
        var w: *Wobble = @ptrCast(@alignCast(ptr));

        // TODO: maybe node should enforce this
        if (w.out == null) {
            return;
        }

        const result = w.base_pitch.?.get() + w.amp.?.get() * std.math.sin(w.phase);

        w.phase += std.math.tau * w.frequency.?.get() * w.ctx.inv_sample_rate;

        while (w.phase >= std.math.tau) {
            w.phase -= std.math.tau;
        }

        w.out.?.set(result);
    }

    pub fn node(ptr: *Wobble) Node {
        return Node.init(ptr, Wobble);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const config = zounds.ContextConfig{
        .frames_per_packet = 1,
        .desired_format = .{
            .sample_format = .f32,
            .sample_rate = 44_100,
            .channels = zounds.ChannelPosition.fromChannelCount(2),
            .is_interleaved = true,
        },
    };

    var signal_ctx = try zounds.signals.Context.init(alloc);

    var new_osc_a = zounds.dsp.Oscillator{
        .ctx = &signal_ctx,
        .pitch = .{ .static = zounds.utils.pitchFromNote(60) },
        .amp = .{ .static = 1.0 },
    };
    var new_osc_node_a = new_osc_a.node();

    _ = try signal_ctx.registerNode(&new_osc_node_a);

    var wobb = Wobble{
        .ctx = &signal_ctx,
        .frequency = .{ .static = 50.0 },
        .base_pitch = .{ .static = zounds.utils.pitchFromNote(63) },
    };
    var wobb_node = wobb.node();

    _ = try signal_ctx.registerNode(&wobb_node);

    var new_osc_b = zounds.dsp.Oscillator{
        .ctx = &signal_ctx,
        .pitch = wobb.out,
        .amp = .{ .static = 1.0 },
    };
    var new_osc_node_b = new_osc_b.node();

    _ = try signal_ctx.registerNode(&new_osc_node_b);

    var new_osc_c = zounds.dsp.Oscillator{
        .ctx = &signal_ctx,
        .pitch = .{ .static = zounds.utils.pitchFromNote(67) },
        .amp = .{ .static = 1.0 },
    };
    var new_osc_node_c = new_osc_c.node();

    _ = try signal_ctx.registerNode(&new_osc_node_c);

    var new_osc_d = zounds.dsp.Oscillator{
        .ctx = &signal_ctx,
        .pitch = .{ .static = zounds.utils.pitchFromNote(69) },
        .amp = .{ .static = 1.0 },
    };
    var new_osc_node_d = new_osc_d.node();

    _ = try signal_ctx.registerNode(&new_osc_node_d);

    var new_chord = try zounds.dsp.Sink.init(&signal_ctx);
    // TODO: cant release memory without ensuring the render thread is done first
    //defer new_chord.deinit();

    var new_chord_node = new_chord.node();

    _ = try signal_ctx.registerNode(&new_chord_node);

    _ = try new_chord.inputs.append(new_osc_node_a.out(0).single.*);
    _ = try new_chord.inputs.append(new_osc_node_b.out(0).single.*);
    _ = try new_chord.inputs.append(new_osc_node_c.out(0).single.*);
    _ = try new_chord.inputs.append(new_osc_node_d.out(0).single.*);

    // TODO: audio context should derive its sample rate from available backend devices/formats
    var player_ctx = try zounds.Context.init(.coreaudio, alloc, config);

    var trigger: bool = false;

    // TODO: ADSR utility function for quickly generating 4-tuple ramp list
    const adsr: [4]zounds.envelope.Ramp = .{
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
            .duration = .{ .seconds = 0.5 },
        },
        .{ // sustain
            .from = 0.7,
            .to = 0.5,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.8 },
        },
        .{ // release
            .from = 0.5,
            .to = 0.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.3 },
        },
    };
    _ = adsr;

    signal_ctx.sink = new_chord.out;
    _ = try signal_ctx.node_list.?.append(wobb_node);

    std.debug.print("node list:\t", .{});
    for (signal_ctx.node_list.?) |n| {
        std.debug.print("{s}, ", .{n.id});
    }
    std.debug.print("\n", .{});

    var context_source = signal_ctx.source();

    const device: zounds.Device = .{
        .sample_rate = 44_100,
        .channels = zounds.ChannelPosition.fromChannelCount(2),
        .id = "fake_device",
        .name = "Fake Device",
        .formats = &.{},
    };

    const options: zounds.StreamOptions = .{
        .write_ref = &context_source,
        .format = config.desired_format,
    };

    const player = try player_ctx.createPlayer(device, &writeFn, options);
    _ = try player.setVolume(-20.0);

    player.play();

    std.time.sleep(std.time.ns_per_ms * 1000);

    // ta
    trigger = true;
    std.debug.print("ta", .{});
    std.time.sleep(std.time.ns_per_ms * 180);

    trigger = false;
    std.time.sleep(std.time.ns_per_ms * 50);

    // dah~
    trigger = true;
    std.debug.print("-dah~\n", .{});
    std.time.sleep(std.time.ns_per_ms * 3000);

    std.debug.print("ctx ticks:\t{}\n", .{signal_ctx.ticks});
}

pub fn writeFn(ref: *anyopaque, buf: []u8) void {
    _ = ref;
    _ = buf;
}
