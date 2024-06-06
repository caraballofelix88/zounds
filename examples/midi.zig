const std = @import("std");
const zounds = @import("zounds");

const PolySynth = struct {
    ctx: *const zounds.signals.AudioContext,
    osc: *zounds.signals.TestWavetableOscNode,
    active_notes: *[]SynthNote,

    pub fn nextFn(ptr: *anyopaque) f32 {
        var p: *PolySynth = @ptrCast(@alignCast(ptr));

        var out: f32 = undefined;

        for (p.active_notes.*) |*note| {
            p.osc.pitch = .{ .static = zounds.utils.pitchFromNote(note.value) };
            p.osc.amp = .{ .node = note.envelope.node() };
            out += p.osc.node().signal().get();
        }

        out /= @floatFromInt(p.active_notes.len);

        return out;
    }

    pub fn node(w: *PolySynth) zounds.signals.Node(f32) {
        return .{ .ptr = w, .nextFn = nextFn };
    }
};

const SynthNote = struct {
    value: u8,
    envelope: zounds.envelope.Envelope,
};

// TODO: synth playback
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    const config = zounds.ContextConfig{
        .desired_format = .{
            .sample_format = .f32,
            .sample_rate = 44_100,
            .channels = zounds.ChannelPosition.fromChannelCount(2),
        },
        .frames_per_packet = 1,
    };

    var audio_ctx = zounds.signals.AudioContext{ .sample_rate = 44_100 };

    var signal_osc = zounds.signals.TestWavetableOscNode{
        .ctx = &audio_ctx,
        .pitch = .{ .static = 440.0 },
        .amp = .{ .static = 1.0 },
    };

    var active_notes = std.ArrayList(SynthNote).init(alloc);
    defer active_notes.deinit();

    var synth = PolySynth{
        .active_notes = &active_notes.items,
        .osc = &signal_osc,
        .ctx = &audio_ctx,
    };

    var context_source = audio_ctx.source();

    var bufferSource = try zounds.sources.BufferSource.init(alloc, &context_source);
    defer bufferSource.deinit();

    audio_ctx.sink = synth.node().signal();

    var playerContext = try zounds.Context.init(.coreaudio, alloc, config);
    defer playerContext.deinit();

    var player_source = bufferSource.source();

    const dummy_device = zounds.Device{
        .id = "dummy_device",
        .name = "Dummy Device",
        .channels = undefined,
        .formats = std.meta.tags(zounds.SampleFormat),
        .sample_rate = 44_100,
    };

    var player = try playerContext.createPlayer(dummy_device, &writeFn, .{
        .format = config.desired_format,
        .write_ref = &player_source,
    });
    _ = try player.setVolume(-20.0);

    var queue: std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = std.fifo.LinearFifo(zounds.midi.Message, .Dynamic).init(alloc);

    var mutex = std.Thread.Mutex{};

    // TODO: split out midi backends
    const on_update_struct = zounds.coreaudio.Midi.ClientCallbackStruct{ .cb = &midiCallback, .ref = @ptrCast(@constCast(&queue)), .mut = &mutex };

    var midi_client = try zounds.coreaudio.Midi.Client.init(alloc, &on_update_struct);

    defer midi_client.deinit();

    player.play();

    var input_buffer: [25]u8 = undefined;
    var selected_option: u8 = 0;

    const adsr: [4]zounds.envelope.Ramp = .{
        .{ // attack
            .from = 0.0,
            .to = 1.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.05 },
        },
        .{ // decay
            .from = 1.0,
            .to = 0.7,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.5 },
        },
        .{ // sustain
            .from = 0.7,
            .to = 0.5,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.8 },
        },
        .{ // release
            .from = 0.5,
            .to = 0.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.3 },
        },
    };

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
            if (msg.status.kind() == .note_on and msg.data & 0xFF00 == 0x2c00) { // TODO: what note is this, lol?
                should_stop = true;
            }

            const note: u8 = @truncate(msg.data >> 8);

            if (msg.status.kind() == .note_on) {
                const note_idx: ?usize = blk: {
                    for (active_notes.items, 0..) |n, idx| {
                        if (n.value == note) {
                            break :blk idx;
                        }
                    }
                    break :blk null;
                };
                if (note_idx) |idx| {
                    active_notes.items[idx].envelope.attack();
                } else {
                    var env = zounds.envelope.Envelope.init(&adsr, .{ .static = false });
                    env.attack();
                    try active_notes.append(SynthNote{ .value = note, .envelope = env });
                }
            } else if (msg.status.kind() == .note_off) {
                const note_idx: ?usize = blk: {
                    for (active_notes.items, 0..) |n, idx| {
                        if (n.value == note) {
                            break :blk idx;
                        }
                    }
                    break :blk null;
                };

                // set release
                if (note_idx) |idx| {
                    active_notes.items[idx].envelope.release();
                }
            }
        }

        // sweep active notes for completed envs
        const epsilon = 0.005;

        // TODO: iterating across array as we delete from it is breaking
        // Happens when we remove multiple notes in same frame?
        for (active_notes.items, 0..) |n, idx| {
            if (n.envelope.ramp_index >= 1 and n.envelope.latest_value <= epsilon) {
                _ = active_notes.swapRemove(idx);
            }
        }
    }

    player.pause();
}

pub fn writeFn(ref: *anyopaque, buf: []u8) void {
    _ = ref;
    _ = buf;
}

// TODO: maybe add listener pattern for tracking a list of midi queue receivers?
fn midiCallback(sent_msg: *const zounds.midi.Message, queue_ptr: *anyopaque) callconv(.C) void {
    var queue: *std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = @ptrCast(@constCast(@alignCast(queue_ptr)));

    _ = queue.writeItem(sent_msg.*) catch |err| {
        std.debug.print("Midi message queue append error:\t{}\n", .{err});
    };
}
