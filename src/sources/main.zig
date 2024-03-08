const std = @import("std");

const main = @import("../main.zig");
const osc = @import("./osc.zig");
const buffered = @import("./buffered.zig");
const wav = @import("../readers/wav.zig");
const clock = @import("../clock.zig");
const utils = @import("../utils.zig");

pub const AudioSource = struct {
    ptr: *anyopaque,
    nextFn: *const fn (ptr: *anyopaque) ?[]u8,
    hasNextFn: *const fn (ptr: *anyopaque) bool,

    pub fn next(self: *AudioSource) ?[]u8 {
        return self.nextFn(self.ptr);
    }

    pub fn hasNext(self: *AudioSource) bool {
        return self.hasNextFn(self.ptr);
    }
};

pub const OscillatorSource = struct {
    iterator: osc.SineIterator(0.5, 440, 44_100),

    pub fn init() OscillatorSource {
        const iterator = osc.SineIterator(0.5, 440, 44_100){};

        return .{ .iterator = iterator };
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *OscillatorSource = @ptrCast(@alignCast(ptr));

        return s.iterator.next();
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(self: *OscillatorSource) AudioSource {
        return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

pub const SampleSource = struct {
    alloc: std.mem.Allocator,
    iterator: buffered.BufferIterator,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !SampleSource {
        const buf = try wav.readWav(alloc, path);

        const iterator = buffered.BufferIterator.init(buf);

        return .{ .alloc = alloc, .iterator = iterator };
    }

    pub fn deinit(s: *SampleSource) void {
        s.alloc.destroy(s.buf);
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *SampleSource = @ptrCast(@alignCast(ptr));

        return s.iterator.next();
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        const s: *SampleSource = @ptrCast(@alignCast(ptr));
        return s.iterator.hasNext();
    }

    pub fn source(self: *SampleSource) AudioSource {
        return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

pub const BufferSource = struct {
    alloc: std.mem.Allocator,
    in_source: *AudioSource,
    buf: *std.RingBuffer,
    size: usize,

    pub fn init(alloc: std.mem.Allocator, in_source: *AudioSource) !BufferSource {
        // hardcoded size for now
        const size: usize = @as(usize, main.SampleFormat.f32.size()) * 44_100 * 2; // 2 seconds of samples

        const buf = try alloc.create(std.RingBuffer);
        buf.* = try std.RingBuffer.init(alloc, size);

        return .{ .alloc = alloc, .in_source = in_source, .buf = buf, .size = size };
    }

    pub fn deinit(s: *BufferSource) void {
        s.buf.deinit(s.alloc);
        s.alloc.destroy(s.buf);
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *BufferSource = @ptrCast(@alignCast(ptr));

        if (s.in_source.next()) |sample| {
            s.buf.writeSliceAssumeCapacity(sample);

            return sample;
        }
        return null;
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        const s: *BufferSource = @ptrCast(@alignCast(ptr));
        return s.in_source.hasNext();
    }

    pub fn source(self: *BufferSource) AudioSource {
        return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

// TODO: generalize one and zero based on sample type
const zero: [4]u8 = std.mem.zeroes([4]u8);
const one: [4]u8 = @bitCast(@as(f32, 1.0));

// TODO: break out into a separate file for timekeeping/clock stuff
pub const TickSource = struct {
    bpm: u32,
    ticks: u64 = 0,

    pub fn init(bpm: u32) TickSource {
        return .{ .bpm = bpm };
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *TickSource = @ptrCast(@alignCast(ptr));

        const samples_per_min = 60 * 44_100;
        const samples_per_beat = samples_per_min / s.bpm;
        const tick_interval = 2000; // do this in beats

        s.ticks += 1;

        var result: []u8 = undefined;
        if (s.ticks >= samples_per_beat) {
            result = @constCast(one[0..]);
        } else {
            result = @constCast(zero[0..]);
        }

        if (s.ticks >= samples_per_beat + tick_interval) {
            s.ticks = 0;
        }

        return result;
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(self: *TickSource) AudioSource {
        return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

// TODO: rename, more of a gate, really
pub const MuxSource = struct {
    a: AudioSource,
    b: AudioSource,
    buf: [4]u8 = undefined,

    pub fn init(a: AudioSource, b: AudioSource) MuxSource {
        return .{ .a = a, .b = b };
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *MuxSource = @ptrCast(@alignCast(ptr));

        const a: ?[]u8 = s.a.next();
        const b: ?[]u8 = s.b.next();

        // TODO: ugly casting to do math, find out how to really clean this up
        const fl_a: f32 = std.mem.bytesAsValue(f32, a.?).*;
        const fl_b: f32 = std.mem.bytesAsValue(f32, b.?).*;

        const result = fl_a * fl_b;

        std.debug.print("mux result: {}\n", .{result});

        s.buf = @bitCast(result);

        return s.buf[0..];
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(self: *MuxSource) AudioSource {
        return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

// why does this sound so bad
// lol why did i duplicate this
pub const AddSource = struct {
    a: AudioSource,
    b: AudioSource,
    buf: [4]u8 = undefined,

    pub fn init(a: AudioSource, b: AudioSource) AddSource {
        return .{ .a = a, .b = b };
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *AddSource = @ptrCast(@alignCast(ptr));

        const a: ?[]u8 = s.a.next();
        const b: ?[]u8 = s.b.next();

        // TODO: ugly casting to do math, find out how to really clean this up

        const fl_a: f32 = std.mem.bytesAsValue(f32, a.?).*;
        const fl_b: f32 = std.mem.bytesAsValue(f32, b.?).*;

        const result = (fl_a + fl_b) * 0.5;

        s.buf = @bitCast(result);

        return s.buf[0..];
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(self: *AddSource) AudioSource {
        return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

// TODO: this sounds bad
const megalovania = .{ // 60 = C4, i think?
    clock.Note{ .pitch = 59, .duration = .sixteenth },
    clock.Note{ .pitch = 0, .duration = .sixteenth },

    clock.Note{ .pitch = 59, .duration = .sixteenth },

    clock.Note{ .pitch = 74, .duration = .eighth },
    clock.Note{ .pitch = 74, .duration = .sixteenth },
    clock.Note{ .pitch = 0, .duration = .quarter },
    clock.Note{ .pitch = 45, .duration = .quarter },

    clock.Note{ .pitch = 0, .duration = .whole },
    clock.Note{ .pitch = 0, .duration = .whole },
};

const simple_notes = .{
    clock.Note{ .pitch = 60, .duration = .quarter },
    // clock.Note{ .pitch = 62, .duration = .quarter },
    // clock.Note{ .pitch = 64, .duration = .quarter },
    // clock.Note{ .pitch = 65, .duration = .quarter },
};

// represents a single
pub const SequenceSource = struct {
    //sources: []AudioSource,
    iterator: *osc.WavetableIterator,
    bpm: u32,
    ticks: u64 = 0,
    notes: []const clock.Note = &simple_notes,
    note_index: usize = 0,

    pub fn init(iterator: *osc.WavetableIterator, bpm: u32) SequenceSource {
        const s = SequenceSource{ .bpm = bpm, .iterator = iterator };

        // NOTE: non-obvious iterator state change
        iterator.setPitch(utils.pitchFromNote(s.notes[0].pitch));
        return s;
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *SequenceSource = @ptrCast(@alignCast(ptr));

        s.ticks += 1;

        const curr_note = s.notes[s.note_index];
        const tick_interval: u32 = @intFromFloat(curr_note.duration.sampleInterval(44_100, s.bpm));

        if (s.ticks >= tick_interval) {
            s.note_index += 1;
            s.ticks = 0;

            std.debug.print("||||| \t ticks: {} \t interval: {} \t note: {}\n", .{ s.ticks, tick_interval, s.note_index });
            if (s.note_index >= s.notes.len) {
                std.debug.print("note sequence complete\n", .{});
                s.note_index = 0;
            }
        }
        // feels like something we needn't do every iteration
        s.iterator.setPitch(utils.pitchFromNote(curr_note.pitch));

        return s.iterator.next().?;
    }

    // TODO: are sequences finite? do we just loop?
    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(self: *SequenceSource) AudioSource {
        return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

pub const AudioNode = struct {
    in: ?*AudioNode,
    out: ?*AudioNode,
    graph: ?*AudioGraph,
    name: []const u8,

    pub fn init(name: []const u8) AudioNode {
        return AudioNode{ .in = null, .out = null, .graph = null, .name = name };
    }
};
// TODO: implement node structure with sources
const AudioGraph = struct { alloc: std.mem.Allocator, nodes: AudioNode, sample_rate: u32, sample_ticks: u64 };
