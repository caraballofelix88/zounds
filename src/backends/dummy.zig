const std = @import("std");
const main = @import("../main.zig");
const sources = @import("../sources/main.zig");
const backends = @import("backends.zig");

pub const dummy_device = main.Device{
    .id = "dummy_device",
    .name = "Dummy Device",
    .channels = undefined,
    .formats = std.meta.tags(main.SampleFormat),
    .sample_rate = 44_100,
};

pub const Context = struct {
    alloc: std.mem.Allocator,
    device_list: std.ArrayListUnmanaged(main.Device),

    pub fn init(allocator: std.mem.Allocator, config: main.ContextConfig) !backends.Context {
        _ = config;
        const ctx = try allocator.create(Context);

        ctx.* = .{ .alloc = allocator, .device_list = .{ .items = undefined } };

        return .{ .dummy = ctx };
    }

    pub fn deinit(ctx: *Context) void {
        // TODO:
        _ = ctx;
    }

    pub fn refresh(ctx: *Context) void {
        //TODO:
        _ = ctx;
    }

    pub fn devices(ctx: Context) []const main.Device {
        return ctx.device_list.items;
    }

    pub fn defaultDevice(ctx: Context) ?main.Device {
        return ctx.device_list.items[0];
    }

    pub fn createPlayer(ctx: *Context, device: main.Device, writeFn: main.WriteFn, options: main.StreamOptions) !backends.Player {
        _ = device;
        _ = writeFn;
        _ = options;

        const p = try ctx.alloc.create(Player);

        p.* = .{
            .alloc = ctx.alloc,
            .is_paused = false,
        };

        return .{ .dummy = p };
    }

    // TODO: copypasted from coreaudio, probably not necessary for dummy. Consider how to consume raw signal, though
    pub fn renderCallback(refPtr: ?*anyopaque, buf: []u8, num_frames: usize) void {
        const player: *Player = @ptrCast(@alignCast(refPtr));

        // TODO: move render stuff into writeFn
        const writeFn: main.WriteFn = player.writeFn;
        _ = writeFn;

        var source: *sources.AudioSource = @ptrCast(@alignCast(player.write_ref));

        // TODO: this can be format-independent if we count samples over byte by byte???
        // byte-per-byte should resolve channel playback as well as format size
        var cast_buf: [*]f32 = @ptrCast(@alignCast(buf));

        const sample_size = 4; // TODO: pull in from player context
        const num_samples = num_frames * 2;

        var frame: u32 = 0;

        while (frame < num_samples) : (frame += 2) { // TODO: manually interleave channels for stereo for now

            const nextSample: f32 = std.mem.bytesAsValue(f32, source.next().?[0..sample_size]).*;

            cast_buf[frame] = std.math.clamp(nextSample, -1.0, 1.0);
            cast_buf[frame + 1] = std.math.clamp(nextSample, -1.0, 1.0);
            // buf[frame + 1] = fromIterR; //std.math.shr(f64, fromIter, 32) | fromIter;
        }
    }
};

pub const Player = struct {
    alloc: std.mem.Allocator,
    is_paused: bool,
    vol: f32 = 0.0,

    pub fn deinit(p: *Player) void {
        p.alloc.destroy(p);
    }

    pub fn play(p: *Player) void {
        p.is_paused = false;
    }

    pub fn pause(p: *Player) !void {
        p.is_paused = true;
    }

    pub fn paused(p: *Player) bool {
        return p.is_paused;
    }

    pub fn setVolume(p: *Player, vol: f32) !void {
        p.vol = vol;
    }

    pub fn volume(p: *Player) !f32 {
        return p.vol;
    }
};
