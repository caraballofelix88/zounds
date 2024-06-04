const std = @import("std");
const zounds = @import("zounds");

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

    // TODO: audio context should derive its sample rate from available backend devices/formats
    var audio_ctx = zounds.signals.AudioContext{ .sample_rate = 44_100 };
    var player_ctx = try zounds.Context.init(.dummy, alloc, config);

    var signal = zounds.signals.TestWavetableOscNode{
        .ctx = &audio_ctx,
        .pitch = .{ .static = zounds.utils.pitchFromNote(60) },
        .amp = .{ .static = 1.0 },
    };

    audio_ctx.sink = signal.node().signal();
    var context_source = audio_ctx.source();

    const options: zounds.StreamOptions = .{
        .write_ref = &context_source,
        .format = config.desired_format,
    };

    const device: zounds.Device = .{
        .sample_rate = 44_100,
        .channels = zounds.ChannelPosition.fromChannelCount(2),
        .id = "fake_device",
        .name = "Fake Device",
        .formats = &.{},
    };

    const player = try player_ctx.createPlayer(device, &writeFn, options);

    std.debug.print("Playing...\n", .{});
    player.play();
    std.time.sleep(std.time.ns_per_s * 3);
    player.pause();
    std.debug.print("Done!\n", .{});
}

pub fn writeFn(ref: *anyopaque, buf: []u8) void {
    _ = ref;
    _ = buf;
}
