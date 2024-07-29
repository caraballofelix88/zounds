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
    var adsr_node = try graph_ctx.register(&adsr);

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

    var chord_node = try graph_ctx.register(&chord);

    // plug adsr into oscillators, plug oscillators into chord
    const note_nodes: []const *Node = &.{ c_node, e_node, g_node };
    for (note_nodes, 0..) |note, idx| {
        var field_name_buf: [32]u8 = undefined;
        const field_str = try std.fmt.bufPrint(&field_name_buf, "in_{}", .{idx + 1});
        try graph_ctx.connect(chord_node.port(field_str), note.port("out"));
        try graph_ctx.connect(note.port("amp"), adsr_node.port("out"));
    }

    // assign root signal to signal graph
    signal_graph.root_signal = chord_node.port("out").*;

    // TODO: audio context should derive its sample rate from available backend devices/formats, not the raw desired config
    var player_ctx = try zounds.Context.init(.coreaudio, alloc, config);

    const device: zounds.Device = .{
        .sample_rate = 44_100,
        .channels = zounds.ChannelPosition.fromChannelCount(2),
        .id = "fake_device",
        .name = "Fake Device",
        .formats = &.{},
    };

    const options: zounds.StreamOptions = .{
        .write_ref = &graph_ctx,
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

    std.debug.print("ctx ticks:\t{}\n", .{graph_ctx.ticks()});
}

pub fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    var graph: *zounds.signals.GraphContext = @ptrCast(@alignCast(write_ref));

    const sample_buf: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);

    for (0..num_frames) |frame_idx| {
        const curr_frame = graph.opts.channel_count * frame_idx;
        @memcpy(sample_buf[curr_frame .. curr_frame + graph.opts.channel_count], graph.next());
    }
}
