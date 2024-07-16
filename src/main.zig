const std = @import("std");
const testing = std.testing;
pub const sources = @import("sources/main.zig");
pub const utils = @import("utils.zig");
pub const filters = @import("filters.zig");
pub const envelope = @import("envelope.zig");
pub const signals = @import("signals.zig");
pub const midi = @import("midi.zig");
pub const readers = @import("readers/readers.zig");
pub const backends = @import("backends/backends.zig");
pub const dsp = @import("dsp/dsp.zig");

// TODO: midi client backends
pub const coreaudio = @import("backends/coreaudio.zig");

pub const Backend = backends.Backend;

pub const Context = struct {
    alloc: std.mem.Allocator,
    backend: backends.Context,
    //signal: signals.Context,

    pub fn init(comptime backend: ?Backend, allocator: std.mem.Allocator, config: ContextConfig) !Context {
        const backend_ctx: backends.Context = blk: {
            if (backend) |b| {
                break :blk try @typeInfo(
                    std.meta.fieldInfo(backends.Context, b).type,
                ).Pointer.child.init(allocator, config);
            }
            // TODO: iterate through list of available backends if not specified
        };

        // const signal_ctx = signals.Context{};

        return .{
            .alloc = allocator,
            .backend = backend_ctx,
            // .signal = signal_ctx,
        };
    }

    pub inline fn deinit(ctx: *Context) void {
        return switch (ctx.backend) {
            inline else => |b| b.deinit(),
        };
    }

    pub inline fn createPlayer(ctx: Context, device: Device, writeFn: WriteFn, options: StreamOptions) !Player {
        return .{
            .backend = switch (ctx.backend) {
                inline else => |b| try b.createPlayer(device, writeFn, options),
            },
        };
    }

    pub inline fn devices(ctx: Context) []const Device {
        return .{ .backend = switch (ctx.backend) {
            inline else => |b| try b.devices(),
        } };
    }
};

pub const Player = struct {
    backend: backends.Player,

    pub inline fn play(p: Player) void {
        return switch (p.backend) {
            inline else => |b| b.play(),
        };
    }

    pub inline fn pause(p: Player) void {
        return switch (p.backend) {
            inline else => |b| b.play(),
        };
    }

    pub inline fn setVolume(p: Player, vol: f32) !void {
        return switch (p.backend) {
            inline else => |b| try b.setVolume(vol),
        };
    }

    pub inline fn deinit(p: *Player) void {
        return switch (p.backend) {
            inline else => |b| b.deinit(),
        };
    }
};

pub const SampleFormat = enum {
    f32,
    i16,

    pub fn size(fmt: SampleFormat) u8 {
        return bitSize(fmt) / 8;
    }

    pub fn bitSize(fmt: SampleFormat) u8 {
        return switch (fmt) {
            .f32 => 32,
            .i16 => 16,
        };
    }

    pub fn fmtType(comptime fmt: SampleFormat) type {
        return switch (fmt) {
            .f32 => f32,
            .i16 => i16,
        };
    }
};

pub const FormatData = struct {
    sample_format: SampleFormat,
    channels: []const ChannelPosition,
    sample_rate: u32,
    is_interleaved: bool = true, // channel samples interleaved?

    pub fn frameSize(f: FormatData) usize {
        return f.sample_format.size() * f.channels.len;
    }

    pub fn invSampleRate(f: FormatData) f32 {
        return 1.0 / @as(f32, @floatFromInt(f.sample_rate));
    }
};

pub const AudioBuffer = struct {
    format: FormatData,
    buf: []const u8,

    pub fn sampleCount(b: AudioBuffer) usize {
        return b.buf.len / b.format.sample_format.size();
    }

    pub fn frameCount(b: AudioBuffer) usize {
        return b.buf.len / b.format.frameSize();
    }

    pub fn trackLength(b: AudioBuffer) usize { // in seconds
        return b.sampleCount() / b.format.sample_rate;
    }
};

pub const ContextConfig = struct {
    desired_format: FormatData,
    frames_per_packet: u8, // TODO: this is more of a stream option concern
};

pub const ChannelPosition = enum {
    left,
    right,

    pub const mono: [1]ChannelPosition = .{.left};
    pub const stereo: [2]ChannelPosition = .{ .left, .right };

    pub fn fromChannelCount(count: usize) []const ChannelPosition {
        return switch (count) {
            1 => &mono,
            2 => &stereo,
            else => &mono,
        };
    }
};

test "ChannelPosition.fromChannelCount" {
    try testing.expectEqualSlices(ChannelPosition, &.{.left}, ChannelPosition.fromChannelCount(1));
    try testing.expectEqualSlices(ChannelPosition, &.{ .left, .right }, ChannelPosition.fromChannelCount(2));
}

pub const MidiClientContext = struct {};

// Audio input/output (output TK)
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    channels: []const ChannelPosition,
    sample_rate: u24,
    formats: []const SampleFormat,
};

pub const StreamOptions = struct {
    format: FormatData,
    write_ref: *anyopaque,
};

pub const WriteFn = *const fn (player_opaque: *anyopaque, output: []u8, num_frames: usize) void;
