const std = @import("std");

const zgui = @import("zgui");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");

const zounds = @import("zounds");

const renderers = @import("renderers/main.zig");

const window_title = "zights and zounds";

const AppState = struct {
    alloc: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,

    player: *zounds.Player,

    // player config
    vol: f32,

    // audio source config
    pitchNote: i32,

    // should be wrapped in some audio node kind of thing
    wave_iterator: *zounds.WavetableIterator,
};

const AudioNode = struct {};

const AudioGraph = struct { alloc: std.mem.Allocator, nodes: AudioNode };

pub fn main() !void {
    _ = try zglfw.init();
    defer zglfw.terminate();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const window = try zglfw.Window.create(400, 400, window_title, null);
    defer window.destroy();
    window.setSizeLimits(1400, 1400, -1, -1);

    const gctx = try zgpu.GraphicsContext.create(alloc, window, .{});
    defer gctx.destroy(alloc);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    zgui.init(alloc);
    defer zgui.deinit();

    zgui.backend.init(
        window,
        gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    zgui.getStyle().scaleAllSizes(scale_factor);

    const config = zounds.Context.Config{ .sample_format = .f32, .sample_rate = 44_100, .channel_count = 2, .frames_per_packet = 1 };

    const wave_iterator = try alloc.create(zounds.WavetableIterator);
    defer alloc.destroy(wave_iterator);

    wave_iterator.* = .{
        .wavetable = @constCast(&zounds.sineWave),
        .pitch = 440.0,
        .sample_rate = 44_100,
    };

    const playerContext = try zounds.CoreAudioContext.init(alloc, config);
    defer playerContext.deinit();

    const player = try playerContext.createPlayer(@constCast(&wave_iterator.source()));
    _ = try player.setVolume(-20.0);
    const state = try alloc.create(AppState);
    defer alloc.destroy(state);

    state.* = .{ .alloc = alloc, .gctx = gctx, .player = player, .pitchNote = 76, .vol = -20.0, .wave_iterator = wave_iterator };

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        update(state);
        draw(state);
    }
}

fn update(app: *AppState) void {
    const gctx = app.gctx;
    const player = app.player;

    zgui.backend.newFrame(
        gctx.swapchain_descriptor.width,
        gctx.swapchain_descriptor.height,
    );

    // Set the starting window position and size to custom values
    zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

    if (zgui.begin("Player Controls", .{})) {
        if (player.is_playing) {
            if (zgui.button("Pause", .{ .w = 200.0 })) {
                std.debug.print("Pausing player\n", .{});
                player.pause();
            }
        } else {
            if (zgui.button("Play", .{ .w = 200.0 })) {
                std.debug.print("Playing player\n", .{});
                player.play();
            }
        }

        if (zgui.sliderFloat("Volume (dB)", .{ .v = &app.vol, .min = -40.0, .max = 0.0 })) {
            // set Volume
            _ = try player.setVolume(app.vol);
        }
        if (zgui.sliderInt("Pitch", .{
            .v = &app.pitchNote,
            .min = 0,
            .max = 127,
        })) {
            // update pitch
            app.wave_iterator.setPitch(zounds.utils.pitchFromNote(app.pitchNote));
        }
        zgui.end();
    }

    if (zgui.begin("Plot", .{})) {
        try renderers.renderPlot();
        zgui.end();
    }
}

fn draw(app: *AppState) void {
    const gctx = app.gctx;

    // const fb_width = gctx.swapchain_descriptor.width;
    // const fb_height = gctx.swapchain_descriptor.height;

    const swapchain_texv = gctx.swapchain.getCurrentTextureView();
    defer swapchain_texv.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // GUI pass
        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
            defer zgpu.endReleasePass(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}
