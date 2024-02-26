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
    sound_buffer: *std.RingBuffer,

    // player config
    vol: f32,

    // audio source config
    pitchNote: i32,

    // should be wrapped in some audio node kind of thing
    wave_iterator: *zounds.WavetableIterator,
    sequence_source: *zounds.sources.SequenceSource,
    rand: std.rand.Random,

    window: *zglfw.Window,
    bpm: i32 = 120,
    // was space pressed last frame?
    space_pressed: bool = false,
};

pub fn main() !void {
    _ = try zglfw.init();
    defer zglfw.terminate();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const window = try zglfw.Window.create(1400, 700, window_title, null);
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

    const tick_iterator = try alloc.create(zounds.WavetableIterator);
    defer alloc.destroy(tick_iterator);

    tick_iterator.* = .{
        .wavetable = @constCast(&zounds.hiss),
        .pitch = 50.0,
        .sample_rate = 44_100,
    };

    var sequence = try alloc.create(zounds.sources.SequenceSource);
    sequence.* = zounds.sources.SequenceSource.init(wave_iterator, 120);

    //var tick = try alloc.create(zounds.sources.TickSource);
    // tick.* = zounds.sources.TickSource.init(120);

    //var mux = zounds.sources.MuxSource.init(tick_iterator.source(), tick.source());
    //var add = zounds.sources.AddSource.init(sequence.source(), mux.source());

    var bufferSource = try zounds.sources.BufferSource.init(alloc, sequence.source());
    defer bufferSource.deinit();

    const playerContext = try zounds.CoreAudioContext.init(alloc, config);
    defer playerContext.deinit();

    const player = try playerContext.createPlayer(@constCast(&bufferSource.source()));
    _ = try player.setVolume(-20.0);
    const state = try alloc.create(AppState);
    defer alloc.destroy(state);

    var rand = std.rand.DefaultPrng.init(0);

    state.* = .{
        .alloc = alloc,
        .gctx = gctx,
        .player = player,
        .pitchNote = 76,
        .vol = -20.0,
        .wave_iterator = wave_iterator,
        .sound_buffer = bufferSource.buf,
        .rand = rand.random(),
        .window = window,
        .sequence_source = sequence,
    };

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        try update(state);
        draw(state);
    }
}

fn keyCallback(
    window: *zglfw.Window,
    key: zglfw.Key,
    scancode: i32,
    action: zglfw.Action,
    mods: zglfw.Mods,
) callconv(.C) void {
    _ = window;
    _ = mods;
    _ = scancode;
    if (action == .press) {
        std.debug.print("key pressed: {}\n", .{key});
    }
}

fn update(app: *AppState) !void {
    const gctx = app.gctx;
    const player = app.player;

    const window = app.window;

    if (window.getKey(.space) == .press) {
        // button positive edge
        if (app.space_pressed == false) {
            if (player.is_playing) {
                player.pause();
            } else {
                player.play();
            }
        }
        app.space_pressed = true;
    } else {
        app.space_pressed = false;
    }

    const keys = .{ .a, .s, .d, .f };
    _ = keys;
    _ = window.setKeyCallback(keyCallback);

    zgui.backend.newFrame(
        gctx.swapchain_descriptor.width,
        gctx.swapchain_descriptor.height,
    );

    // Set the starting window position and size to custom values
    // zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
    // zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

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

        if (zgui.sliderFloat("Volume (dB)", .{ .v = &app.vol, .min = -30.0, .max = -10.0 })) {
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

        if (zgui.sliderInt("Tick BPM", .{ .v = &app.bpm, .min = 20, .max = 300 })) {
            app.sequence_source.bpm = @intCast(app.bpm);
        }

        if (zgui.button("Reset sequencer counter", .{})) {
            std.debug.print("reset sequence\n", .{});
            app.sequence_source.note_index = 0;
            app.sequence_source.ticks = 0;
        }

        zgui.end();
    }

    if (zgui.begin("Plot", .{})) {
        try renderers.renderPlot(app.sound_buffer);
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
