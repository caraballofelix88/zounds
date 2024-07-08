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

    var signal_ctx = zounds.signals.Context{};

    // file buffer
    const file_buf = try zounds.readers.wav.readWavFile(alloc, "res/PinkPanther30.wav");

    var buffer_playback = zounds.dsp.BufferPlayback{ .ctx = &signal_ctx, .buf = file_buf };
    var buf_node = buffer_playback.node();
    _ = try signal_ctx.registerNode(&buf_node);

    var player_ctx = try zounds.Context.init(.coreaudio, alloc, config);

    signal_ctx.sink = buffer_playback.out;

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

    std.time.sleep(std.time.ns_per_ms * 10000);
}

pub fn writeFn(ref: *anyopaque, buf: []u8) void {
    _ = ref;
    _ = buf;
}
