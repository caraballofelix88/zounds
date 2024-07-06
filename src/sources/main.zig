const std = @import("std");

const main = @import("../main.zig");
const wav = @import("../readers/wav.zig");
const clock = @import("../clock.zig");
const utils = @import("../utils.zig");

pub const AudioSource = struct {
    ptr: *anyopaque,
    nextFn: *const fn (ptr: *anyopaque) ?[]u8,
    hasNextFn: *const fn (ptr: *anyopaque) bool,

    pub fn next(self: AudioSource) ?[]u8 {
        return self.nextFn(self.ptr);
    }

    pub fn hasNext(self: AudioSource) bool {
        return self.hasNextFn(self.ptr);
    }
};

// pub const SampleSource = struct {
//     alloc: std.mem.Allocator,
//     iterator: buffered.BufferIterator,
//
//     pub fn init(alloc: std.mem.Allocator, path: []const u8) !SampleSource {
//         const buf = try wav.readWavFile(alloc, path);
//
//         const iterator = buffered.BufferIterator{ .buf = buf };
//
//         return .{ .alloc = alloc, .iterator = iterator };
//     }
//
//     pub fn deinit(s: *SampleSource) void {
//         s.alloc.destroy(s.buf);
//     }
//
//     pub fn nextFn(ptr: *anyopaque) ?[]u8 {
//         const s: *SampleSource = @ptrCast(@alignCast(ptr));
//
//         return s.iterator.next();
//     }
//
//     pub fn hasNextFn(ptr: *anyopaque) bool {
//         const s: *SampleSource = @ptrCast(@alignCast(ptr));
//         return s.iterator.hasNext();
//     }
//
//     pub fn source(self: *SampleSource) AudioSource {
//         return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
//     }
// };

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

// TODO: break out into a separate file for timekeeping/clock stuff
pub const MetronomeSource = struct {
    bpm: u32,
    ticks: u64 = 0,

    pub fn init(bpm: u32) MetronomeSource {
        return .{ .bpm = bpm };
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        const s: *MetronomeSource = @ptrCast(@alignCast(ptr));

        const samples_per_min = 60 * 44_100;
        const samples_per_beat = samples_per_min / s.bpm;
        const tick_interval = 2000; // do this in beats

        s.ticks += 1;

        var result: []u8 = undefined;
        if (s.ticks >= samples_per_beat) {
            const one: f32 = 1.0;
            result = @bitCast(one);
        } else {
            const zero: f32 = 0.0;
            result = zero;
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

    pub fn source(self: *MetronomeSource) AudioSource {
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

// pub const SequenceSource = struct {
//     iterator: *osc.WavetableIterator,
//     bpm: u32,
//     ticks: u64 = 0,
//     notes: []const clock.Note = &simple_notes,
//     note_index: usize = 0,
//
//     pub fn init(iterator: *osc.WavetableIterator, bpm: u32) SequenceSource {
//         const s = SequenceSource{ .bpm = bpm, .iterator = iterator };
//
//         // NOTE: non-obvious iterator state change
//         iterator.setPitch(utils.pitchFromNote(s.notes[0].pitch));
//         return s;
//     }
//
//     pub fn nextFn(ptr: *anyopaque) ?[]u8 {
//         const s: *SequenceSource = @ptrCast(@alignCast(ptr));
//
//         s.ticks += 1;
//
//         const curr_note = s.notes[s.note_index];
//         const tick_interval: u32 = curr_note.duration.sampleInterval(44_100, s.bpm);
//
//         if (s.ticks >= tick_interval) {
//             s.note_index += 1;
//             s.ticks = 0;
//
//             if (s.note_index >= s.notes.len) {
//                 s.note_index = 0;
//             }
//         }
//         // feels like something we needn't do every iteration
//         s.iterator.setPitch(utils.pitchFromNote(curr_note.pitch));
//
//         return s.iterator.next();
//     }
//
//     // TODO: are sequences finite? do we just loop?
//     pub fn hasNextFn(ptr: *anyopaque) bool {
//         _ = ptr;
//         return true;
//     }
//
//     pub fn source(self: *SequenceSource) AudioSource {
//         return .{ .ptr = self, .nextFn = nextFn, .hasNextFn = hasNextFn };
//     }
// };
