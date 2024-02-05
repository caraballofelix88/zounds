const std = @import("std");
const coreaudio = @import("backends/coreaudio.zig");
const sources = @import("sources/main.zig");
const osc = @import("sources/osc.zig");

pub const SampleFormat = enum {
    f32,

    pub fn size(fmt: SampleFormat) u8 {
        return bitSize(fmt) / 8;
    }

    pub fn bitSize(fmt: SampleFormat) u8 {
        return switch (fmt) {
            .f32 => 32,
        };
    }

    pub fn fmtType(comptime fmt: SampleFormat) type {
        return switch (fmt) {
            .f32 => f32,
        };
    }
};

pub const Context = struct {
    pub const Config = struct {
        sample_format: SampleFormat,
        sample_rate: u32,
        channel_count: u8,
        frames_per_packet: u8,
    };
};

const ChannelPosition = enum { left, right };

pub const Device = struct { ptr: *anyopaque, name: []u8, channels: []ChannelPosition, sample_rate: u24, sample_fmt: SampleFormat };

pub fn doTheThing() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const config = Context.Config{ .sample_format = .f32, .sample_rate = 44_100, .channel_count = 2, .frames_per_packet = 1 };
    const playerContext = try coreaudio.Context.init(alloc, config);

    std.debug.print("Context:\n{}\n", .{playerContext});
    defer playerContext.deinit();

    var source = try sources.SampleSource.init(alloc, "res/nicer_laugh.wav");
    _ = source;
    // TODO: sample source deinit

    comptime var wavIterator = osc.WavetableIterator{ .wavetable = @constCast(&osc.waveTable), .pitch = 440.0, .sample_rate = 44_100 };
    comptime var lerpWave = osc.WavetableIterator{ .wavetable = @constCast(&osc.waveTable), .pitch = 440.0, .sample_rate = 44_100, .withLerp = true };
    comptime var bigWave = osc.WavetableIterator{ .wavetable = @constCast(&osc.bigWave), .pitch = 440.0, .sample_rate = 44_100, .withLerp = true };
    var player = try playerContext.createPlayer(@constCast(&wavIterator.source()));

    _ = try player.setVolume(0.5);
    player.play();
    std.log.debug("running", .{});
    std.time.sleep(1000 * std.time.ns_per_ms);
    player.setAudioSource(@constCast(&lerpWave.source()));

    var currPitch = lerpWave.pitch;
    for (0..100) |_| {
        currPitch += 5;
        lerpWave.setPitch(currPitch);
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    player.setAudioSource(@constCast(&bigWave.source()));
    std.time.sleep(1000 * std.time.ns_per_ms);

    std.log.debug("done", .{});
}
