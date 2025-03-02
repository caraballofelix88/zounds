const std = @import("std");
const z = @import("../root.zig");
const backend_context = @import("../context.zig");
const backends = @import("backends.zig");

pub const dummy_device = z.Device{
    .id = "dummy_device",
    .name = "Dummy Device",
    .channels = undefined,
    .formats = std.meta.tags(z.SampleFormat),
    .sample_rate = 44_100,
};

pub const Context = struct {
    alloc: std.mem.Allocator,
    device_list: std.ArrayListUnmanaged(z.Device),

    pub fn init(allocator: std.mem.Allocator, config: backend_context.ContextConfig) !backends.Context {
        _ = config;
        const ctx = try allocator.create(Context);

        ctx.* = .{ .alloc = allocator, .device_list = .empty };

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

    pub fn devices(ctx: Context) []const z.Device {
        return ctx.device_list.items;
    }

    pub fn defaultDevice(ctx: Context) ?z.Device {
        return ctx.device_list.items[0];
    }

    pub fn createPlayer(ctx: *Context, device: z.Device, writeFn: z.WriteFn, options: z.StreamOptions) !backends.Player {
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

        const writeFn: z.WriteFn = player.writeFn;

        writeFn(player.write_ref, buf[0 .. num_frames * player.ctx.format.frameSize()], num_frames);
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

    pub fn pause(p: *Player) void {
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
