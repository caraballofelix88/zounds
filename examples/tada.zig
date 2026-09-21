const std = @import("std");
const zounds = @import("zounds");

const fmt = zounds.fmt;

const Signal = zounds.Signal;
const Node = zounds.Node;

const log = std.log.scoped(.examples_tada);

pub fn main(init_data: std.process.Init) !void {
    const alloc = init_data.gpa;

    const format: fmt.FormatData = .{
        .sample_format = .f32,
        .sample_rate = 44_100,
        .channels = fmt.ChannelPosition.fromChannelCount(2),
        .is_interleaved = true,
    };

    const config = zounds.backend_context.ContextConfig{ .frames_per_packet = 1, .desired_format = format };

    var signal_graph = zounds.Graph(.{ .channel_count = 2 }){ .format = config.desired_format };
    var graph_ctx = signal_graph.context();

    // build trigger for chord envelope
    var trigger: f32 = 0.0;
    const trigger_signal: Signal = .{ .ptr = &trigger };

    var adsr = zounds.dsp.ADSR{ .ctx = graph_ctx, .trigger = .{ .ptr = &trigger } };
    const adsr_hdl = try graph_ctx.register(&adsr);
    const adsr_node = graph_ctx.getNode(adsr_hdl).?;
    _ = adsr_node; // autofix

    var osc_c = try zounds.voices.AdditiveVoice.init(.{
        .id = "osc c",
        .ctx = graph_ctx,
        .trigger = trigger_signal,
        .pitch = zounds.utils.pitchFromNote(60),
        .format = format,
    }, alloc);
    const c_node = try graph_ctx.register(&osc_c);

    var osc_e = try zounds.voices.AdditiveVoice.init(.{
        .id = "osc e",
        .ctx = graph_ctx,
        .trigger = trigger_signal,
        .pitch = zounds.utils.pitchFromNote(65),
        .format = format,
    }, alloc);
    const e_node = try graph_ctx.register(&osc_e);

    var osc_g = try zounds.voices.AdditiveVoice.init(.{
        .id = "osc g",
        .ctx = graph_ctx,
        .format = format,
        .trigger = trigger_signal,
        .pitch = zounds.utils.pitchFromNote(69),
    }, alloc);

    const g_node = try graph_ctx.register(&osc_g);

    var chord = zounds.dsp.Sink(3){ .ctx = graph_ctx };

    const chord_hdl = try graph_ctx.register(&chord);
    var chord_node = graph_ctx.getNode(chord_hdl).?;

    // plug adsr into oscillators, plug oscillators into chord
    const note_hdls: []const zounds.Handle = &.{ c_node, e_node, g_node };
    for (note_hdls, 0..) |hdl, idx| {
        var field_name_buf: [32]u8 = undefined;

        var note_node = graph_ctx.getNode(hdl).?;

        const field_str = try std.fmt.bufPrint(&field_name_buf, "in_{}", .{idx + 1});
        try graph_ctx.connect(chord_node.port(field_str).field_ptr, note_node.port("out").field_ptr);
    }

    // assign root signal to signal graph
    signal_graph.root_signal = chord_node.port("out").field_ptr.*;

    // TODO: audio context should derive its sample rate from available backend devices/formats, not the raw desired config
    var player_ctx = try zounds.Context.init(null, alloc, config);

    const device: zounds.Device = .{
        .sample_rate = 44_100,
        .channels = fmt.ChannelPosition.fromChannelCount(2),
        .id = "fake_device",
        .name = "Fake Device",
        .formats = &.{},
    };

    const options: zounds.StreamOptions = .{
        .write_ref = @ptrCast(@constCast(graph_ctx)),
        .format = format,
    };

    var player = try player_ctx.createPlayer(device, &writeFn, options);
    defer player.deinit();
    _ = try player.setVolume(-20.0);

    player.play();

    // std.time.sleep(std.time.ns_per_ms * 500);
    try std.Io.sleep(init_data.io, .fromMilliseconds(500), .real);

    // ta
    trigger = 1.0;
    log.debug("ta", .{});
    // std.time.sleep(std.time.ns_per_ms * 180);
    try std.Io.sleep(init_data.io, .fromMilliseconds(180), .real);

    trigger = 0.0;
    // std.time.sleep(std.time.ns_per_ms * 50);
    try std.Io.sleep(init_data.io, .fromMilliseconds(50), .real);

    // dah~
    trigger = 1.0;
    log.debug("-dah~\n", .{});
    // std.time.sleep(std.time.ns_per_ms * 3000);
    try std.Io.sleep(init_data.io, .fromMilliseconds(3000), .real);

    log.debug("ctx ticks:\t{}\n", .{graph_ctx.ticks()});
}

pub fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    var graph: *zounds.GraphContext = @ptrCast(@alignCast(write_ref));

    const sample_buf: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);

    for (0..num_frames) |frame_idx| {
        const curr_frame = graph.opts.channel_count * frame_idx;
        @memcpy(sample_buf[curr_frame .. curr_frame + graph.opts.channel_count], graph.next());
    }
}
