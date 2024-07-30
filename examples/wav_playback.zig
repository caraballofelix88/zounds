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

    var graph = zounds.signals.Graph(.{}){
        .format = config.desired_format,
    };
    var graph_ctx = graph.context();

    var filter = zounds.dsp.Filter{ .ctx = graph_ctx, .filter_type = .high_pass };
    var filter_node = filter.node();
    _ = try graph_ctx.register(&filter_node);

    // file buffer
    const file_buf = try zounds.readers.wav.readWavFile(alloc, "res/test.wav");

    var buffer_playback = zounds.dsp.BufferPlayback{ .ctx = graph_ctx, .buf = file_buf };
    var buf_node = buffer_playback.node();
    _ = try graph_ctx.register(&buf_node);

    try graph_ctx.connect(filter_node.port("in"), buf_node.port("out"));
    graph.root_signal = filter_node.port("out").*;

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

    const player = try player_ctx.createPlayer(device, &writeFn, options);
    _ = try player.setVolume(-20.0);

    player.play();

    std.time.sleep(std.time.ns_per_ms * 10000);
}

pub fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    var graph: *zounds.signals.GraphContext = @ptrCast(@alignCast(write_ref));

    const sample_buf: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);

    for (0..num_frames) |frame_idx| {
        const curr_frame = graph.opts.channel_count * frame_idx;
        @memcpy(sample_buf[curr_frame .. curr_frame + graph.opts.channel_count], graph.next());
    }
}
