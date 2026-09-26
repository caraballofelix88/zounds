const std = @import("std");
const testing = std.testing;

pub const backends = @import("backends/backends.zig");
pub const Backend = backends.Backend;
pub const coreaudio = @import("backends/coreaudio.zig");
pub const dsp = @import("dsp/dsp.zig");
pub const envelope = @import("envelope.zig");
pub const fmt = @import("audio_format.zig");
pub const midi = @import("midi.zig");
pub const readers = @import("readers/readers.zig");
pub const utils = @import("utils.zig");
pub const voices = @import("voices/voices.zig");
pub const wavegen = @import("wavegen.zig");
pub const backend_context = @import("context.zig");

const old_signals = @import("signals.zig");
pub const Node = old_signals.Node;
pub const Graph = old_signals.Graph;
pub const GraphOptions = old_signals.Options;
pub const GraphContext = old_signals.GraphContext;
pub const Handle = old_signals.Handle;

const core_signal = @import("core/signal.zig");
pub const Signal = core_signal.Signal;
pub const Ports = core_signal.Ports;

// TODO: midi client backends
pub const Context = struct {
    alloc: std.mem.Allocator,
    backend: backends.Context,

    pub fn init(comptime backend: ?Backend, allocator: std.mem.Allocator, config: backend_context.ContextConfig) !Context {
        const backend_ctx: backends.Context = blk: {
            if (backend) |b| {
                break :blk try @typeInfo(
                    std.meta.fieldInfo(backends.Context, b).type,
                ).Pointer.child.init(allocator, config);
            }
            // TODO: iterate through list of available backends if not specified
            else {
                inline for (std.meta.fields(Backend), 0..) |b, i| {
                    const backend_type = @typeInfo(
                        std.meta.fieldInfo(backends.Context, @as(Backend, @enumFromInt(b.value))).type,
                    );
                    if (backend_type.pointer.child.init(allocator, config)) |d| {
                        break :blk d;
                    } else |err| {
                        if (i == std.meta.fields(Backend).len - 1)
                            return err;
                    }
                }
                unreachable;
            }
        };

        return .{
            .alloc = allocator,
            .backend = backend_ctx,
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
            inline else => |b| b.pause(),
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

pub const MidiClientContext = struct {};

// Audio input/output (output TK)
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    channels: []const fmt.ChannelPosition,
    sample_rate: u24,
    formats: []const fmt.SampleFormat,
    alloc: ?std.mem.Allocator = null,

    pub fn deinit(device: *Device) void {
        if (device.alloc) |alloc| {
            alloc.free(device.id);
            alloc.free(device.name);
        }
    }
};

pub const StreamOptions = struct {
    format: fmt.FormatData,
    write_ref: *anyopaque,
};

pub const WriteFn = *const fn (player_opaque: *anyopaque, output: []u8, num_frames: usize) void;
