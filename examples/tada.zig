const std = @import("std");
const zounds = @import("zounds");

const Signal = zounds.signals.Signal;
const Node = zounds.signals.Node;

// simple LFO
const Wobble = struct {
    ctx: *zounds.signals.Context,
    id: []const u8 = "wobb",
    base_pitch: Signal = .{ .static = 440.0 },
    frequency: Signal = .{ .static = 10.0 },

    amp: Signal = .{ .static = 10.0 },
    out: Signal = .{ .static = 0.0 },
    phase: f32 = 0,

    pub const ins = .{ .base_pitch, .frequency, .amp };
    pub const outs = .{.out};

    pub fn process(ptr: *anyopaque) void {
        var w: *Wobble = @ptrCast(@alignCast(ptr));

        const result = w.base_pitch.get() + w.amp.get() * std.math.sin(w.phase);

        w.phase += std.math.tau * w.frequency.get() * w.ctx.inv_sample_rate;

        while (w.phase >= std.math.tau) {
            w.phase -= std.math.tau;
        }

        w.out.set(result);
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
            .sample_rate = 22_050,
            .channels = zounds.ChannelPosition.fromChannelCount(2),
            .is_interleaved = true,
        },
    };

    var signal_ctx = zounds.signals.Context{
        .sample_rate = 22_050,
        .inv_sample_rate = 1.0 / 22_050.0,
    };

    var osc_c = zounds.dsp.Oscillator{
        .ctx = &signal_ctx,
        .id = "Osc:C",
        .pitch = .{ .static = zounds.utils.pitchFromNote(60) },
    };
    var c_node = osc_c.node();

    _ = try signal_ctx.registerNode(&c_node);

    var wobbly_e = Wobble{
        .ctx = &signal_ctx,
        .id = "Wobble",
        .frequency = .{ .static = 3.0 },
        .base_pitch = .{ .static = zounds.utils.pitchFromNote(65) },
        .amp = .{ .static = 4.0 },
    };
    var wobb_node = wobbly_e.node();

    _ = try signal_ctx.registerNode(&wobb_node);

    var osc_e = zounds.dsp.Oscillator{
        .ctx = &signal_ctx,
        .id = "Osc:E",
        .pitch = wobbly_e.out,
    };
    var e_node = osc_e.node();

    _ = try signal_ctx.registerNode(&e_node);

    var osc_g = zounds.dsp.Oscillator{
        .ctx = &signal_ctx,
        .id = "Osc:G",
        .pitch = .{ .static = zounds.utils.pitchFromNote(69) },
    };
    var g_node = osc_g.node();

    _ = try signal_ctx.registerNode(&g_node);

    var chord = zounds.dsp.Sink.init(&signal_ctx, alloc);
    // TODO: cant release memory without ensuring the render thread is done first
    defer chord.deinit();

    var new_chord_node = chord.node();
    _ = try signal_ctx.registerNode(&new_chord_node);

    _ = try chord.inputs.append(c_node.out(0).single.*);
    _ = try chord.inputs.append(e_node.out(0).single.*);
    _ = try chord.inputs.append(g_node.out(0).single.*);

    // TODO: audio context should derive its sample rate from available backend devices/formats, not the raw desired config
    var player_ctx = try zounds.Context.init(.coreaudio, alloc, config);

    var trigger: f32 = 0.0;
    var adsr = zounds.dsp.ADSR(.{}){ .ctx = &signal_ctx, .trigger = .{ .ptr = &trigger } };
    var adsr_node = adsr.node();

    _ = try signal_ctx.registerNode(&adsr_node);

    chord.amp = adsr.out;

    signal_ctx.sink = chord.out;
    try signal_ctx.buildProcessList();

    signal_ctx.printNodeList();

    var context_source = signal_ctx.source();

    const device: zounds.Device = .{
        .sample_rate = 22_050,
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

    std.time.sleep(std.time.ns_per_ms * 500);

    // ta
    trigger = 1.0;
    std.debug.print("ta", .{});
    std.time.sleep(std.time.ns_per_ms * 180);

    trigger = 0.0;
    std.time.sleep(std.time.ns_per_ms * 50);

    // dah~
    trigger = 1.0;
    std.debug.print("-dah~\n", .{});
    std.time.sleep(std.time.ns_per_ms * 3000);

    std.debug.print("ctx ticks:\t{}\n", .{signal_ctx.ticks});
}

pub fn writeFn(ref: *anyopaque, buf: []u8) void {
    _ = ref;
    _ = buf;
}
