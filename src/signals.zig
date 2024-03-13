const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");

const AudioContext = struct {
    sample_rate: u32,
    ticks: u64,
    fmt: main.FormatData,

    src: *AudioSource,

    pub fn next(ctx: *AudioContext) f32 {
        ctx.ticks += 1;
        return ctx.src.next();
    }
};

pub fn AudioSource(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        nextFn: *const fn (ptr: *anyopaque) T,

        const Self = @This();
        // hasNextFn: *const fn (ptr: *anyopaque) bool,

        pub fn next(self: Self) T {
            return self.nextFn(self.ptr);
        }

        // pub fn hasNext(self: AudioSource) bool {
        //     return self.hasNextFn(self.ptr);
        // }
    };
}

const TestNode = struct {
    current: f32 = 0.0,

    pub fn next(s: *TestNode) f32 {
        s.current += 1.0;
        return @mod(s.current, 10.0);
    }

    pub fn nextFn(ptr: *anyopaque) f32 {
        const tn: *TestNode = @ptrCast(@alignCast(ptr));
        return tn.next();
    }

    pub fn source(self: *TestNode) AudioSource(f32) {
        return .{ .ptr = self, .nextFn = nextFn };
    }
};

const SignalValueTags = enum {
    static,
    source,
    ptr,
};

// Signal represents a value that can be provided as a static value or derived from a source
const Signal = union(SignalValueTags) {
    static: f32,
    source: AudioSource(f32),
    ptr: *const f32,

    pub fn get(s: Signal) f32 {
        return switch (s) {
            .static => |val| val,
            .source => |src| src.next(),
            .ptr => |ptr| ptr.*,
        };
    }
};

test "Signal" {
    const static_signal = Signal{ .static = 2.0 };
    try testing.expectEqual(2.0, static_signal.get());
    try testing.expectEqual(2.0, static_signal.get());

    var node = TestNode{};
    const src_signal: Signal = .{ .source = node.source() };

    try testing.expectEqual(1.0, src_signal.get());
    try testing.expectEqual(2.0, src_signal.get());
    try testing.expectEqual(3.0, src_signal.get());
    try testing.expectEqual(4.0, src_signal.get());

    var val: f32 = 1.0;
    const ptr_signal: Signal = .{ .ptr = &val };

    try testing.expectEqual(1.0, ptr_signal.get());

    val = 5.0;

    try testing.expectEqual(5.0, ptr_signal.get());
}
