const std = @import("std");
const zounds = @import("zounds");

const NoteSynth = struct {
    note: u8,
    trigger: f32 = 0, // really just 1 or 0 for now, but could eventually be note velocity
    amp: f32 = 0, // output of adsr envelope
    val: f32 = 0, // latest computed output
    osc: ?*zounds.dsp.Oscillator = null,
    envelope: ?*zounds.dsp.ADSR = null,
};

// TODO: how to implement voices? ADSR + filter + a couple of oscs, nested in a single config?
const PolySynth = struct {
    id: []const u8 = "zynthezizer",
    ctx: zounds.signals.GraphContext,
    alloc: std.mem.Allocator,
    active_notes: std.MultiArrayList(NoteSynth),
    mutex: std.Thread.Mutex,

    out: zounds.signals.Signal = .{ .static = 0.0 },

    pub const ins = .{};
    pub const outs = .{.out};

    const default_osc = .{};
    const default_env = zounds.envelope.generateADSR(.{});

    pub fn init(ctx: zounds.signals.GraphContext, alloc: std.mem.Allocator) !PolySynth {
        return .{ .ctx = ctx, .alloc = alloc, .active_notes = std.MultiArrayList(NoteSynth){}, .mutex = std.Thread.Mutex{} };
    }

    pub fn deinit(s: *PolySynth) void {
        for (s.active_notes.items(.osc), s.active_notes.items(.envelope)) |*osc, *env| {
            s.alloc.destroy(osc);
            s.alloc.destroy(env);
        }
        s.active_notes.deinit(s.alloc);

        s.mutex.unlock();
    }

    pub fn process(ptr: *anyopaque) void {
        var s: *PolySynth = @ptrCast(@alignCast(ptr));

        s.mutex.lock();
        defer s.mutex.unlock();
        errdefer s.mutex.unlock();

        var result: f32 = undefined;

        for (0..s.active_notes.len) |idx| {
            s.active_notes.items(.envelope)[idx].?.node().process();
            s.active_notes.items(.osc)[idx].?.node().process();
            result += s.active_notes.items(.val)[idx];
        }

        // TODO: this gets crunchy anywhere beyond 4 voices at once, how to regulate amplitude envelope with dynamic number of sources?
        result /= 4;

        // purge completed notes
        var purge_idx: usize = 0;
        while (purge_idx < s.active_notes.len) {
            const adsr = s.active_notes.items(.envelope)[purge_idx].?;
            if (adsr.state == .off) {
                s.alloc.destroy(s.active_notes.items(.osc)[purge_idx].?);
                s.alloc.destroy(s.active_notes.items(.envelope)[purge_idx].?);
                s.active_notes.swapRemove(purge_idx);

                // after swap, reassign pointers for swapped note, if it exists
                // TODO: this would be totally unnecessary if node graph context does in/out bookkeeping for us instead of doing it manually
                // How to add nested nodes to context?
                if (purge_idx < s.active_notes.len) {
                    s.active_notes.items(.envelope)[purge_idx].?.*.trigger = .{ .ptr = &s.active_notes.items(.trigger)[purge_idx] };
                    s.active_notes.items(.envelope)[purge_idx].?.*.out = .{ .ptr = &s.active_notes.items(.amp)[purge_idx] };
                    s.active_notes.items(.osc)[purge_idx].?.*.amp = .{ .ptr = &s.active_notes.items(.amp)[purge_idx] };
                    s.active_notes.items(.osc)[purge_idx].?.*.out = .{ .ptr = &s.active_notes.items(.val)[purge_idx] };
                }

                std.debug.print("result: {}, active_notes: {}\n", .{ result, s.active_notes.len });
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
            .note = val,
            .trigger = 1.0,
        };

        try s.active_notes.append(s.alloc, new_note);

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
    var graph_context = graph.context();

    var midi_queue_mutex = std.Thread.Mutex{};

    var poly_synth = try PolySynth.init(graph_context, alloc);
    var poly_synth_node = try graph_context.register(&poly_synth);

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
        .write_ref = &graph_context,
    });
    defer player.deinit();
    _ = try player.setVolume(-20.0);

    var midi_msg_queue: std.fifo.LinearFifo(zounds.midi.Message, .Dynamic) = std.fifo.LinearFifo(zounds.midi.Message, .Dynamic).init(alloc);

    // TODO: split out midi backends
    const on_update_struct = zounds.midi.ClientCallbackStruct{ .cb = &midiCallback, .ref = @ptrCast(@constCast(&midi_msg_queue)), .mut = &midi_queue_mutex };

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

    graph.root_signal = poly_synth_node.port("out").*;

    try midi_client.connectInputSource(selected_option - 1);
    player.play();

    var should_stop = false;
    while (!should_stop) {
        std.time.sleep(std.time.ns_per_ms * 16); // approx 60fps

        midi_queue_mutex.lock();
        defer midi_queue_mutex.unlock();

        while (midi_msg_queue.readItem()) |msg| {
            std.debug.print("Reading msg in main thread:\t{}\t{}\n", .{ msg.status.kind(), msg });
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
        std.debug.print("Midi message queue append error:\t{}\n", .{err});
    };
}
