const std = @import("std");
const zounds = @import("zounds");

const AppState = struct {
    alloc: std.mem.Allocator,
    player: *zounds.Player,
    sound_buffer: *std.RingBuffer,

    // player config
    vol: f32,

    // audio source config
    pitchNote: i32,

    pitch: *f32,

    audio_ctx: *zounds.signals.AudioContext,

    filter_cutoff_hz: i32 = 1000,
    selected_filter: zounds.filters.FilterType = .low_pass,

    player_source: *zounds.sources.AudioSource,

    bpm: i32 = 120,
};

// simple LFO
const Wobble = struct {
    ctx: *const zounds.signals.AudioContext,
    base_pitch: zounds.signals.Signal(f32) = .{ .static = 440.0 },
    frequency: zounds.signals.Signal(f32) = .{ .static = 20.0 },
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

// TODO: NEXT: allow for selection of MIDI input, synth playback
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    _ = stdout;
    _ = stdin;

    const config = zounds.Context.Config{ .sample_format = .f32, .sample_rate = 44_100, .channel_count = 2, .frames_per_packet = 1 };

    var pitch: f32 = 440.0;
    var audio_ctx = zounds.signals.AudioContext{ .sample_rate = 44_100 };

    const true_signal: zounds.signals.Signal(bool) = .{ .static = true };
    var adsr = zounds.envelope.Envelope.init(&zounds.envelope.adsr, true_signal);
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

    const state = try alloc.create(AppState);
    defer alloc.destroy(state);

    state.* = .{
        .alloc = alloc,
        .player = player,
        .pitchNote = 76,
        .pitch = &pitch,
        .vol = -20.0,
        .sound_buffer = bufferSource.buf,
        .player_source = @constCast(&player_source),
        .audio_ctx = &audio_ctx,
    };

    var queue: std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = std.fifo.LinearFifo(zounds.midi.Message, .Dynamic).init(alloc);
    var mutex = std.Thread.Mutex{};
    const on_update_struct = zounds.coreaudio.Midi.ClientCallbackStruct{ .cb = &midiCallback, .ref = @ptrCast(@constCast(&queue)), .mut = &mutex };

    var midi_client = try zounds.coreaudio.Midi.Client.init(alloc, &on_update_struct);

    midi_client.connectInputSource(1);
    defer midi_client.deinit();

    state.player.play();

    var should_stop = false;

    while (!should_stop) {
        std.time.sleep(std.time.ns_per_ms * 16);

        std.Thread.Mutex.lock(&mutex);
        defer std.Thread.Mutex.unlock(&mutex);

        while (queue.readItem()) |msg| {
            std.debug.print("Reading msg in main thread:\t{}\n", .{msg});
            if (msg.status.kind() == .note_on and msg.data & 0xFF00 == 0x4700) {
                should_stop = true;
            }
        }
    }

    state.player.pause();
}

fn midiCallback(sent_msg: *const zounds.midi.Message, queue_ptr: *anyopaque) callconv(.C) void {
    var queue: *std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = @ptrCast(@constCast(@alignCast(queue_ptr)));

    _ = queue.writeItem(sent_msg.*) catch |err| {
        std.debug.print("Callback queue append error:\t{}\n", .{err});
    };

    std.debug.print("Confirming we're writing:\nnumber of elems:{}\tpeeked elem:{}\n\n", .{ queue.readableLength(), queue.peekItem(queue.readableLength() - 1) });
}
