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

    wave_iterator: *zounds.WavetableIterator,
    sequence_source: *zounds.sources.SequenceSource,

    panther_source: *zounds.sources.SampleSource,
    panther_filter: *zounds.filters.Filter,
    filter_cutoff_hz: i32 = 1000,
    selected_filter: zounds.filters.FilterType = .low_pass,

    player_source: *zounds.sources.AudioSource,
    buffer_in: *zounds.sources.AudioSource,

    bpm: i32 = 120,
    // was space pressed last frame?
    space_pressed: bool = false,
    a_pressed: bool = false,
};

export fn windowRescaleFn(window: *zglfw.Window, xscale: f32, yscale: f32) callconv(.C) void {
    zgui.getStyle().scaleAllSizes(@min(xscale, yscale) * window.getContentScale()[0]);
}

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

    const wave_iterator = try alloc.create(zounds.WavetableIterator);
    defer alloc.destroy(wave_iterator);

    var env_adsr = zounds.envelope.Envelope.init(&zounds.envelope.adsr, false);

    wave_iterator.* = .{
        .wavetable = @constCast(&zounds.sineWave),
        .pitch = 1040.0,
        .amp_generator = &env_adsr,
        .sample_rate = 44_100,
    };

    var sequence = try alloc.create(zounds.sources.SequenceSource);
    defer alloc.destroy(sequence);
    sequence.* = zounds.sources.SequenceSource.init(wave_iterator, 120);

    var buffer_in = sequence.source();

    var bufferSource = try zounds.sources.BufferSource.init(alloc, &buffer_in);
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
        .vol = -20.0,
        .wave_iterator = wave_iterator,
        .sound_buffer = bufferSource.buf,
        .window = window,
        .sequence_source = sequence,
        .panther_source = panther_source,
        .panther_filter = @constCast(&panther_filter),
        .selected_source = .osc,
        .player_source = @constCast(&player_source),
        .buffer_in = &buffer_in,
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
        if (!app.a_pressed) {
            if (app.wave_iterator.amp_generator) |env| {
                env.attack();
            }
        }
        app.a_pressed = true;
    } else {
        if (app.a_pressed) {
            if (app.wave_iterator.amp_generator) |env| {
                env.release();
            }
        }
        app.a_pressed = false;
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
                            .osc => app.sequence_source,
                            .sample => app.panther_filter,
                        };
                        app.buffer_in.* = next_source.source();
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
