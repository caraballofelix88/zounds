const std = @import("std");

const main = @import("../main.zig");
const osc = @import("./osc.zig");
const buffered = @import("./buffered.zig");
const wav = @import("../readers/wav.zig");

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
        const iterator = buffered.BufferIterator.init(buf, main.SampleFormat.f32);

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
