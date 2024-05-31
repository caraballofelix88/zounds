const std = @import("std");
const main = @import("../main.zig");
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

    pub fn init(allocator: std.mem.Allocator) backends.Context {
        const ctx = allocator.create(Context);

        ctx.* = .{ .alloc = allocator, .device_list = .{ .items = &.{dummy_device} } };

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
