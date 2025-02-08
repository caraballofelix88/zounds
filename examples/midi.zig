const std = @import("std");
const zounds = @import("zounds");

const log = std.log.scoped(.example_midi);

const NoteSynth = struct {
    alloc: std.mem.Allocator,
    note: u8,
    trigger: f32 = 0, // really just 1 or 0 for now, but could eventually be note velocity
    amp: f32 = 0, // max output of adsr envelope
    val: f32 = 0, // latest computed output
    osc: ?*zounds.dsp.Oscillator = null,
    envelope: ?*zounds.dsp.ADSR = null,
    voice: ?*zounds.voices.AdditiveVoice = null,

    pub fn deinit(v: *NoteSynth) void {
        v.alloc.destroy(v.osc); // TODO: deallocing optionals?
        v.alloc.destroy(v.envelope);

        v.voice.?.deinit();
        v.alloc.destroy(v.voice);
    }
};

// TODO: how to implement voices? ADSR + filter + a couple of oscs, nested in a single config?
//       subgraphs, maybe?
const PolySynth = struct {
    id: []const u8 = "zynthezizer",
    ctx: *const zounds.signals.GraphContext,
    alloc: std.mem.Allocator,
    active_notes: std.MultiArrayList(NoteSynth),
    mutex: std.Thread.Mutex,

    out: zounds.signals.Signal = .{ .static = 0.0 },

    prev_note_count: usize = 0,
    amp: f32 = 1.0,
    amp_ramp_start: u64 = 0,
    amp_ramp: zounds.envelope.Ramp = .{
        .to = 1.0,
        .from = 1.0,
        .duration = .{ .millis = 30 },
        .sample_rate = 44_100, // TODO: should come from ctx, somehow
        .ramp_type = .linear,
    },

    pub const ins = .{};
    pub const outs = .{.out};

    const default_osc = .{};
    const default_env = zounds.envelope.generateADSR(.{});

    pub fn init(ctx: *const zounds.signals.GraphContext, alloc: std.mem.Allocator) !PolySynth {
        return .{ .ctx = ctx, .alloc = alloc, .active_notes = std.MultiArrayList(NoteSynth){}, .mutex = std.Thread.Mutex{} };
    }

    pub fn deinit(s: *PolySynth) void {
        for (s.active_notes.items) |note| {
            note.deinit();
        }
        s.active_notes.deinit(s.alloc);

        s.mutex.unlock();
    }

    pub fn process(ptr: *anyopaque) void {
        var s: *PolySynth = @ptrCast(@alignCast(ptr));

        s.mutex.lock();
        defer s.mutex.unlock();
        errdefer s.mutex.unlock();

        var result: f32 = 0;

        const notes_slice = s.active_notes.slice();
        for (0..notes_slice.len) |idx| {
            // notes_slice.items(.envelope)[idx].?.node().process();
            // notes_slice.items(.osc)[idx].?.node().process();

            zounds.voices.AdditiveVoice.process(notes_slice.items(.voice)[idx].?);

            const val = notes_slice.items(.val)[idx];

            result += val;
        }

        // TODO: this still causes some noticeable jitter while active notes are falling off. What to do?
        // handle amplitude
        // amp for total active notes is calculated as a simple average
        // when active notes change, the amplitude changes starkly from sample to sample, causing noticable clicks
        // ramp amplitude from state to state

        // check change in active notes
        // update ramp to reflect change
        if (s.prev_note_count != s.active_notes.len) {
            s.prev_note_count = s.active_notes.len;
            s.amp_ramp_start = s.ctx.ticks();
            s.amp_ramp.from = s.amp;

            if (s.active_notes.len > 0) {
                s.amp_ramp.to = 1.0 / @as(f32, @floatFromInt(s.active_notes.len));
            } else {
                s.amp_ramp.to = 1.0;
            }
        }

        s.amp = s.amp_ramp.at(s.ctx.ticks() - s.amp_ramp_start);
        result *= s.amp;

        // purge completed notes
        var purge_idx: usize = 0;
        while (purge_idx < s.active_notes.len) {
            const adsr = s.active_notes.items(.envelope)[purge_idx].?;
            _ = adsr; // autofix

            const voice_adsr_state = s.active_notes.items(.voice)[purge_idx].?.adsr_state;

            if (voice_adsr_state == .off) {
                log.debug("purging note {}", .{s.active_notes.items(.note)[purge_idx]});
                s.alloc.destroy(s.active_notes.items(.osc)[purge_idx].?);
                s.alloc.destroy(s.active_notes.items(.envelope)[purge_idx].?);

                s.active_notes.items(.voice)[purge_idx].?.deinit();
                s.alloc.destroy(s.active_notes.items(.voice)[purge_idx].?);

                s.active_notes.swapRemove(purge_idx);

                // after swap, reassign pointers for swapped note, if it exists
                // TODO: this would be totally unnecessary if node graph context does in/out bookkeeping for us instead of doing it manually
                // How to add nested nodes to context?
                if (purge_idx < s.active_notes.len) {
                    s.active_notes.items(.envelope)[purge_idx].?.*.trigger = .{ .ptr = &s.active_notes.items(.trigger)[purge_idx] };
                    s.active_notes.items(.envelope)[purge_idx].?.*.out = .{ .ptr = &s.active_notes.items(.amp)[purge_idx] };
                    s.active_notes.items(.osc)[purge_idx].?.*.amp = .{ .ptr = &s.active_notes.items(.amp)[purge_idx] };
                    s.active_notes.items(.osc)[purge_idx].?.*.out = .{ .ptr = &s.active_notes.items(.val)[purge_idx] };

                    s.active_notes.items(.voice)[purge_idx].?.trigger = .{ .ptr = &s.active_notes.items(.trigger)[purge_idx] };
                    s.active_notes.items(.voice)[purge_idx].?.out = .{ .ptr = &s.active_notes.items(.val)[purge_idx] };
                }
            } else {
                purge_idx += 1;
            }
        }

        s.out.set(result);
    }

    pub fn noteOn(s: *PolySynth, val: u8) !void {
        s.mutex.lock();
        defer s.mutex.unlock();
        errdefer s.mutex.unlock();

        for (0..s.active_notes.len) |idx| {
            if (s.active_notes.items(.note)[idx] == val) {
                s.active_notes.items(.trigger)[idx] = 1.0;
                return;
            }
        }

        const new_note = NoteSynth{
            .alloc = s.alloc,
            .note = val,
            .trigger = 1.0,
        };

        try s.active_notes.append(s.alloc, new_note);

        const voice = try s.alloc.create(zounds.voices.AdditiveVoice);
        voice.* = try zounds.voices.AdditiveVoice.init(.{
            .id = "voice",
            .ctx = s.ctx,
            .amp = 1.0,
            .pitch = zounds.utils.pitchFromNote(val),
            .format = .{
                .sample_format = .f32,
                .sample_rate = 44_100,
                .channels = zounds.ChannelPosition.fromChannelCount(2),
            },
            .trigger = .{ .ptr = &s.active_notes.items(.trigger)[s.active_notes.len - 1] },
        }, s.alloc);
        voice.out = .{ .ptr = &s.active_notes.items(.val)[s.active_notes.len - 1] };

        s.active_notes.items(.voice)[s.active_notes.len - 1] = voice;

        const adsr = try s.alloc.create(zounds.dsp.ADSR);
        adsr.* = zounds.dsp.ADSR{
            .ctx = s.ctx,
            .trigger = .{ .ptr = &s.active_notes.items(.trigger)[s.active_notes.len - 1] },
            .out = .{ .ptr = &s.active_notes.items(.amp)[s.active_notes.len - 1] },
            .ramps = default_env,
        };

        const osc = try s.alloc.create(zounds.dsp.Oscillator);
        osc.* = zounds.dsp.Oscillator{
            .ctx = s.ctx,
            .pitch = .{ .static = zounds.utils.pitchFromNote(val) },
            .amp = adsr.out,
            .out = .{ .ptr = &s.active_notes.items(.val)[s.active_notes.len - 1] },
        };

        s.active_notes.items(.envelope)[s.active_notes.len - 1] = adsr;
        s.active_notes.items(.osc)[s.active_notes.len - 1] = osc;
    }

    pub fn noteOff(s: *PolySynth, val: u8) void {
        s.mutex.lock();
        defer s.mutex.unlock();

        for (0..s.active_notes.len) |idx| {
            const note = s.active_notes.items(.note)[idx];
            if (note == val) {
                s.active_notes.items(.trigger)[idx] = 0.0;
                return;
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
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

    var graph = zounds.signals.Graph(.{}){
        .format = config.desired_format,
    };
    const graph_context = graph.context();

    var midi_queue_mutex = std.Thread.Mutex{};

    var poly_synth = try PolySynth.init(graph_context, alloc);
    const poly_synth_hdl = try graph_context.register(&poly_synth);
    var poly_synth_node = graph_context.getNode(poly_synth_hdl).?;

    var playerContext = try zounds.Context.init(.coreaudio, alloc, config);
    defer playerContext.deinit();

    const dummy_device = zounds.Device{
        .id = "dummy_device",
        .name = "Dummy Device",
        .channels = zounds.ChannelPosition.fromChannelCount(2),
        .formats = std.meta.tags(zounds.SampleFormat),
        .sample_rate = 44_100,
    };

    var player = try playerContext.createPlayer(dummy_device, &writeFn, .{
        .format = config.desired_format,
        .write_ref = @ptrCast(@constCast(graph_context)),
    });
    defer player.deinit();
    _ = try player.setVolume(-20.0);

    var midi_msg_queue: std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = std.fifo.LinearFifo(zounds.midi.Message, .Dynamic).init(alloc);

    // TODO: split out midi backends
    const on_update_struct = zounds.midi.MessageCallbackStruct{ .cb = &midiCallback, .ref = @ptrCast(@constCast(&midi_msg_queue)), .mut = &midi_queue_mutex };

    var midi_client = try zounds.coreaudio.Midi.Client.init(alloc, &on_update_struct);
    defer midi_client.deinit();

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

    graph.root_signal = poly_synth_node.port("out").field_ptr.*;

    try midi_client.connectInputSource(selected_option - 1);
    player.play();

    var should_stop = false;
    while (!should_stop) {
        std.time.sleep(std.time.ns_per_ms * 16); // approx 60fps

        midi_queue_mutex.lock();
        defer midi_queue_mutex.unlock();

        while (midi_msg_queue.readItem()) |msg| {
            log.debug("Reading msg in main thread:\t{}\t{}", .{ msg.status.kind(), msg });
            if (msg.status.kind() == .note_on and msg.data & 0xFF00 == 0x2c00) { // bottom left drum pad on the mpk mini
                should_stop = true;
            }

            const note: u8 = @truncate(msg.data >> 8);

            if (msg.status.kind() == .note_on) {
                try poly_synth.noteOn(note);
            } else if (msg.status.kind() == .note_off) {
                poly_synth.noteOff(note);
            }
        }
    }

    player.pause();
}

pub fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    var graph: *zounds.signals.GraphContext = @ptrCast(@alignCast(write_ref));

    const sample_buf: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);

    for (0..num_frames) |frame_idx| {
        const curr_frame = graph.opts.channel_count * frame_idx;
        const val = graph.next();
        @memcpy(sample_buf[curr_frame .. curr_frame + graph.opts.channel_count], val);
    }
}

// TODO: maybe add listener pattern for tracking a list of midi queue receivers?
fn midiCallback(sent_msg: *const zounds.midi.Message, queue_ptr: *anyopaque) callconv(.C) void {
    var queue: *std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = @ptrCast(@alignCast(queue_ptr));

    _ = queue.writeItem(sent_msg.*) catch |err| {
        log.warn("Midi message queue append error:\t{}", .{err});
    };
}
