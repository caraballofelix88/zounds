const std = @import("std");
const zounds = @import("zounds");

const Signal = zounds.signals.Signal;
const Node = zounds.signals.Node;

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

    var signal_graph = zounds.signals.Graph(.{ .channel_count = 2 }){ .format = config.desired_format };
    var graph_ctx = signal_graph.context();

    // build trigger for chord envelope
    var trigger: f32 = 0.0;
    var adsr = zounds.dsp.ADSR{ .ctx = graph_ctx, .trigger = .{ .ptr = &trigger } };
    const adsr_hdl = try graph_ctx.register(&adsr);
    var adsr_node = graph_ctx.getNode(adsr_hdl).?;

    var osc_c = zounds.dsp.Oscillator{
        .ctx = graph_ctx,
        .id = "Osc:C",
        .pitch = .{ .static = zounds.utils.pitchFromNote(60) },
    };
    const c_node = try graph_ctx.register(&osc_c);

    var osc_e = zounds.dsp.Oscillator{
        .ctx = graph_ctx,
        .id = "Osc:E",
        .pitch = .{ .static = zounds.utils.pitchFromNote(65) },
    };
    const e_node = try graph_ctx.register(&osc_e);

    var osc_g = zounds.dsp.Oscillator{
        .ctx = graph_ctx,
        .id = "Osc:G",
        .pitch = .{ .static = zounds.utils.pitchFromNote(69) },
    };
    const g_node = try graph_ctx.register(&osc_g);

    var chord = zounds.dsp.Sink(3){ .ctx = graph_ctx };

    const chord_hdl = try graph_ctx.register(&chord);
    var chord_node = graph_ctx.getNode(chord_hdl).?;

    // plug adsr into oscillators, plug oscillators into chord
    const note_hdls: []const zounds.signals.Handle = &.{ c_node, e_node, g_node };
    for (note_hdls, 0..) |hdl, idx| {
        var field_name_buf: [32]u8 = undefined;

        var note_node = graph_ctx.getNode(hdl).?;

        const field_str = try std.fmt.bufPrint(&field_name_buf, "in_{}", .{idx + 1});
        try graph_ctx.connect(chord_node.port(field_str).val, note_node.port("out").val);
        try graph_ctx.connect(note_node.port("amp").val, adsr_node.port("out").val);
    }

    // assign root signal to signal graph
    signal_graph.root_signal = chord_node.port("out").val.*;

    // TODO: audio context should derive its sample rate from available backend devices/formats, not the raw desired config
    var player_ctx = try zounds.Context.init(null, alloc, config);

    const device: zounds.Device = .{
        .sample_rate = 44_100,
        .channels = zounds.ChannelPosition.fromChannelCount(2),
        .id = "fake_device",
        .name = "Fake Device",
        .formats = &.{},
    };

    const options: zounds.StreamOptions = .{
        .write_ref = @ptrCast(@constCast(graph_ctx)),
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

    std.log.debug("ctx ticks:\t{}\n", .{graph_ctx.ticks()});
}

pub fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    var graph: *zounds.signals.GraphContext = @ptrCast(@alignCast(write_ref));

    const sample_buf: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);

    for (0..num_frames) |frame_idx| {
        const curr_frame = graph.opts.channel_count * frame_idx;
        @memcpy(sample_buf[curr_frame .. curr_frame + graph.opts.channel_count], graph.next());
    }
}
