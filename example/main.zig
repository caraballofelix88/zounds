const std = @import("std");

const zgui = @import("zgui");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");

const zounds = @import("zounds");

const renderers = @import("renderers/main.zig");

const window_title = "zights and zounds";

pub const NodeCtx = struct {
    x: f32,
    y: f32,
    node: zounds.sources.AudioNode,
    label: [:0]const u8,
};

const SourceSelction = enum(u8) {
    osc = 1,
    sample = 2,
};

const sources = std.meta.fields(SourceSelction);
const filter_types = std.meta.fields(zounds.filters.FilterType);

const AppState = struct {
    alloc: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    window: *zglfw.Window,
    player: *zounds.Player,
    selected_source: SourceSelction,
    sound_buffer: *std.RingBuffer,

    // player config
    vol: f32,

    // audio source config
    pitchNote: i32,

    pitch: *f32,

    audio_ctx: *zounds.signals.AudioContext,

    panther_source: *zounds.sources.SampleSource,
    panther_filter: *zounds.filters.Filter,
    filter_cutoff_hz: i32 = 1000,
    selected_filter: zounds.filters.FilterType = .low_pass,

    player_source: *zounds.sources.AudioSource,

    bpm: i32 = 120,
    // was space pressed last frame?
    space_pressed: bool = false,
    a_pressed: *bool,
};

export fn windowRescaleFn(window: *zglfw.Window, xscale: f32, yscale: f32) callconv(.C) void {
    zgui.getStyle().scaleAllSizes(@min(xscale, yscale) * window.getContentScale()[0]);
}

const Wobble = struct {
    ctx: *const zounds.signals.AudioContext,
    base_pitch: zounds.signals.Signal(f32) = .{ .static = 440.0 },
    frequency: zounds.signals.Signal(f32) = .{ .static = 2.0 },
    amp: zounds.signals.Signal(f32) = .{ .static = 10.0 },
    phase: f32 = 0,

    pub fn nextFn(ptr: *anyopaque) f32 {
        var w: *Wobble = @ptrCast(@alignCast(ptr));

        w.phase += std.math.tau * w.frequency.get() / @as(f32, @floatFromInt(w.ctx.sample_rate));

        while (w.phase >= std.math.tau) {
            w.phase -= std.math.tau;
        }

        return w.base_pitch.get() + w.amp.get() * std.math.sin(w.phase);
    }

    pub fn node(w: *Wobble) zounds.signals.Node(f32) {
        return .{ .ptr = w, .nextFn = nextFn };
    }
};

pub fn main() !void {
    _ = try zglfw.init();
    defer zglfw.terminate();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const window = try zglfw.Window.create(1400, 700, window_title, null);
    defer window.destroy();
    window.setSizeLimits(500, 500, 2000, 2000);

    const gctx = try zgpu.GraphicsContext.create(alloc, window, .{});
    defer gctx.destroy(alloc);

    _ = window.setContentScaleCallback(windowRescaleFn);

    zgui.init(alloc);
    defer zgui.deinit();

    zgui.backend.init(
        window,
        gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    const config = zounds.Context.Config{ .sample_format = .f32, .sample_rate = 44_100, .channel_count = 2, .frames_per_packet = 1 };

    var pitch: f32 = 440.0;
    var audio_ctx = zounds.signals.AudioContext{ .sample_rate = 44_100 };

    var a_pressed = false;
    const button: zounds.signals.Signal(bool) = .{ .ptr = &a_pressed };
    var adsr = zounds.envelope.Envelope.init(&zounds.envelope.adsr, button);
    var wobble = Wobble{ .ctx = &audio_ctx, .base_pitch = .{ .ptr = &pitch } };
    var signal_osc = zounds.signals.TestWavetableOscNode{
        .ctx = &audio_ctx,
        .pitch = wobble.node().signal(),
        .amp = adsr.node().signal(),
    };

    audio_ctx.sink = signal_osc.node().signal();

    var context_source = audio_ctx.source();

    var bufferSource = try zounds.sources.BufferSource.init(alloc, &context_source);
    defer bufferSource.deinit();

    const playerContext = try zounds.CoreAudioContext.init(alloc, config);
    defer playerContext.deinit();

    var player_source = bufferSource.source();

    const player = try playerContext.createPlayer(@constCast(&player_source));
    _ = try player.setVolume(-20.0);

    const panther_source = try alloc.create(zounds.sources.SampleSource);
    panther_source.* = try zounds.sources.SampleSource.init(alloc, "res/PinkPanther30.wav");

    const panther_filter = zounds.filters.Filter.init(panther_source.source());

    const state = try alloc.create(AppState);
    defer alloc.destroy(state);

    state.* = .{
        .alloc = alloc,
        .gctx = gctx,
        .player = player,
        .pitchNote = 76,
        .pitch = &pitch,
        .vol = -20.0,
        .sound_buffer = bufferSource.buf,
        .window = window,
        .panther_source = panther_source,
        .panther_filter = @constCast(&panther_filter),
        .selected_source = .osc,
        .player_source = @constCast(&player_source),
        .audio_ctx = &audio_ctx,
        .a_pressed = &a_pressed,
    };

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        try update(state);
        draw(state);
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

    if (window.getKey(.a) == .press) {
        app.a_pressed.* = true;
    } else {
        app.a_pressed.* = false;
    }

    zgui.backend.newFrame(
        gctx.swapchain_descriptor.width,
        gctx.swapchain_descriptor.height,
    );

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

        if (zgui.treeNode("Select Player Source")) {
            inline for (sources) |source| {
                const curr_source: SourceSelction = @enumFromInt(source.value);
                const selected = app.selected_source == curr_source;

                if (zgui.selectable(source.name, .{ .selected = selected })) {
                    std.debug.print("clicked {s}\n", .{source.name});

                    if (!selected) {
                        app.selected_source = curr_source;
                        const next_source = switch (curr_source) {
                            .osc => app.audio_ctx,
                            .sample => app.panther_filter,
                        };
                        _ = next_source; // TODO: fix reassigning source eventually
                    }
                }
            }
            zgui.treePop();
        }

        zgui.end();
    }

    switch (app.selected_source) {
        .osc => {
            if (zgui.begin("Oscillator controls", .{})) {
                if (zgui.sliderInt("Pitch", .{
                    .v = &app.pitchNote,
                    .min = 0,
                    .max = 127,
                })) {
                    // update pitch
                    app.pitch.* = zounds.utils.pitchFromNote(app.pitchNote);
                }

                if (zgui.sliderInt("Tick BPM", .{ .v = &app.bpm, .min = 20, .max = 300 })) {}

                if (zgui.button("Reset sequencer counter", .{})) {
                    std.debug.print("reset sequence\n", .{});
                }

                zgui.end();
            }
        },
        .sample => {
            if (zgui.begin("Sample controls", .{})) {
                if (zgui.treeNode("Select filter type")) {
                    inline for (filter_types) |filter| {
                        const curr_type: zounds.filters.FilterType = @enumFromInt(filter.value);
                        const selected = app.selected_filter == curr_type;

                        if (zgui.selectable(filter.name, .{ .selected = selected })) {
                            std.debug.print("clicked {s}\n", .{filter.name});

                            if (!selected) {
                                app.selected_filter = curr_type;
                                app.panther_filter.filter_type = curr_type;
                            }
                        }
                    }
                    zgui.treePop();
                }

                if (zgui.sliderInt("cutoff frequency", .{ .min = 0, .max = 10000, .v = &app.filter_cutoff_hz })) {
                    app.panther_filter.cutoff_freq = @intCast(app.filter_cutoff_hz);
                }
                if (zgui.sliderFloat("Q", .{ .min = 0.5, .max = 10.0, .v = &app.panther_filter.q })) {
                    std.debug.print("Filter Q:\t{}\n", .{app.panther_filter.q});
                }
                zgui.end();
            }
        },
    }

    if (zgui.begin("Plot", .{})) {
        try renderers.renderPlot(app.sound_buffer);
        zgui.end();
    }
}

fn draw(app: *AppState) void {
    const gctx = app.gctx;

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
