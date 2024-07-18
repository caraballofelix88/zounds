const std = @import("std");
const zounds = @import("zounds");

const Signal = zounds.signals.Signal;
const Node = zounds.signals.Node;

// simple LFO
const Wobble = struct {
    ctx: zounds.signals.IContext,
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
            .sample_rate = 44_100,
            .channels = zounds.ChannelPosition.fromChannelCount(2),
            .is_interleaved = true,
        },
    };

    var signals = zounds.signals.Context(.{ .channel_count = 2 }){ .format = config.desired_format };
    var signal_ctx = signals.context();

    var osc_c = zounds.dsp.Oscillator{
        .ctx = signal_ctx,
        .id = "Osc:C",
        .pitch = .{ .static = zounds.utils.pitchFromNote(60) },
    };
    var c_node = osc_c.node();

    _ = try signal_ctx.register(&c_node);

    var wobbly_e = Wobble{
        .ctx = signal_ctx,
        .id = "Wobble",
        .frequency = .{ .static = 3.0 },
        .base_pitch = .{ .static = zounds.utils.pitchFromNote(65) },
        .amp = .{ .static = 4.0 },
    };
    var wobb_node = wobbly_e.node();

    _ = try signal_ctx.register(&wobb_node);

    var osc_e = zounds.dsp.Oscillator{
        .ctx = signal_ctx,
        .id = "Osc:E",
        .pitch = wobbly_e.out,
    };
    var e_node = osc_e.node();

    _ = try signal_ctx.register(&e_node);

    var osc_g = zounds.dsp.Oscillator{
        .ctx = signal_ctx,
        .id = "Osc:G",
        .pitch = .{ .static = zounds.utils.pitchFromNote(69) },
    };
    var g_node = osc_g.node();

    _ = try signal_ctx.register(&g_node);

    var chord = zounds.dsp.Sink.init(signal_ctx, alloc);
    defer chord.deinit();

    var new_chord_node = chord.node();
    _ = try signal_ctx.register(&new_chord_node);

    _ = try chord.inputs.append(c_node.out(0).single.*);
    _ = try chord.inputs.append(e_node.out(0).single.*);
    _ = try chord.inputs.append(g_node.out(0).single.*);

    // TODO: audio context should derive its sample rate from available backend devices/formats, not the raw desired config
    var player_ctx = try zounds.Context.init(.coreaudio, alloc, config);

    var trigger: f32 = 0.0;
    var adsr = zounds.dsp.ADSR(.{}){ .ctx = signal_ctx, .trigger = .{ .ptr = &trigger } };
    var adsr_node = adsr.node();

    _ = try signal_ctx.register(&adsr_node);

    chord.amp = adsr.out;

    try signal_ctx.connect(&signals.root_signal, chord.out);

    signals.printNodeList();

    const device: zounds.Device = .{
        .sample_rate = 44_100,
        .channels = zounds.ChannelPosition.fromChannelCount(2),
        .id = "fake_device",
        .name = "Fake Device",
        .formats = &.{},
    };

    const options: zounds.StreamOptions = .{
        .write_ref = &signal_ctx,
        .format = config.desired_format,
    };

    var player = try player_ctx.createPlayer(device, &writeFn, options);
    defer player.deinit();
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

    std.debug.print("ctx ticks:\t{}\n", .{signal_ctx.ticks()});
}

pub fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    // TODO: format, frame size should be passed in w ref?

    var graph: *zounds.signals.IContext = @ptrCast(@alignCast(write_ref));

    const sample_buf: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);

    for (0..num_frames) |frame_idx| {
        const next_frame: []align(1) f32 = std.mem.bytesAsSlice(f32, graph.next());

        const curr_frame = graph.opts.channel_count * frame_idx;

        @memcpy(sample_buf[curr_frame .. curr_frame + graph.opts.channel_count], next_frame);
    }
}
