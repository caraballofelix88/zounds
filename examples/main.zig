const std = @import("std");
const zounds = @import("zounds");

// simple LFO
const Wobble = struct {
    ctx: *const zounds.signals.AudioContext,
    base_pitch: zounds.signals.Signal(f32) = .{ .static = 440.0 },
    frequency: zounds.signals.Signal(f32) = .{ .static = 10.0 },
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

// TODO: synth playback
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

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

    var queue: std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = std.fifo.LinearFifo(zounds.midi.Message, .Dynamic).init(alloc);
    var mutex = std.Thread.Mutex{};
    const on_update_struct = zounds.coreaudio.Midi.ClientCallbackStruct{ .cb = &midiCallback, .ref = @ptrCast(@constCast(&queue)), .mut = &mutex };

    var midi_client = try zounds.coreaudio.Midi.Client.init(alloc, &on_update_struct);

    defer midi_client.deinit();

    player.play();

    var input_buffer: [25]u8 = undefined;
    var selected_option: u8 = 0;

    while (selected_option == 0) {
        try stdout.print("Select MIDI input from available options: \n", .{});

        for (midi_client.available_inputs.items, 0..) |input, idx| {
            try stdout.print("{}:\t{s}\n", .{ idx + 1, input.name });
        }

        try stdout.print("\n\nSelected Option: ", .{});

        const input = try stdin.readUntilDelimiter(&input_buffer, '\n');
        selected_option = try std.fmt.parseInt(u8, @ptrCast(input), 10);

        if (selected_option > midi_client.available_inputs.items.len or selected_option < 0) {
            try stdout.print("Invalid entry. Select from available options.\n\n", .{});
            selected_option = 0;
        } else {
            try stdout.print("Nice, connecting to {s}....\n\n", .{midi_client.available_inputs.items[selected_option - 1].name});
        }
    }

    try midi_client.connectInputSource(selected_option - 1);

    var should_stop = false;
    while (!should_stop) {
        std.time.sleep(std.time.ns_per_ms * 16);

        std.Thread.Mutex.lock(&mutex);
        defer std.Thread.Mutex.unlock(&mutex);

        while (queue.readItem()) |msg| {
            std.debug.print("Reading msg in main thread:\t{}\n", .{msg});
            if (msg.status.kind() == .note_on and msg.data & 0xFF00 == 0x2c00) {
                should_stop = true;
            }
        }
    }

    player.pause();
}

fn midiCallback(sent_msg: *const zounds.midi.Message, queue_ptr: *anyopaque) callconv(.C) void {
    var queue: *std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = @ptrCast(@constCast(@alignCast(queue_ptr)));

    _ = queue.writeItem(sent_msg.*) catch |err| {
        std.debug.print("Midi message queue append error:\t{}\n", .{err});
    };
}
