const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const osc = @import("sources/osc.zig");
const sources = @import("sources/main.zig");

// TODO: rename to something else?
pub const AudioContext = struct {
    sample_rate: u32,
    ticks: u64 = 0, // count of samples played

    sink: ?Signal(f32) = undefined,
    buf: [4]u8 = undefined,

    pub fn next(ctx: *AudioContext) f32 {
        ctx.ticks += 1;

        var result: f32 = undefined;
        if (ctx.sink) |signal| {
            result = signal.get();
        } else {
            result = 0.0;
        }

        ctx.buf = @bitCast(result);

        return result;
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        var ctx: *AudioContext = @ptrCast(@alignCast(ptr));

        // tick ctx
        _ = ctx.next();

        return ctx.buf[0..];
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(ptr: *AudioContext) sources.AudioSource {
        return .{ .ptr = ptr, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

const wave = osc.Wavetable(1024, .sine);

pub const TestWavetableOscNode = struct {
    ctx: *const AudioContext,
    wavetable: []const f32 = &wave,
    pitch: Signal(f32) = .{ .static = 20.0 },
    amp: Signal(f32) = .{ .static = 1.0 },
    buf: [4]u8 = undefined,
    phase: f32 = 0,

    pub fn nextFn(ptr: *anyopaque) f32 {
        var n: *TestWavetableOscNode = @ptrCast(@alignCast(ptr));
        const len: f32 = @floatFromInt(n.wavetable.len);

        const lowInd: usize = @intFromFloat(@floor(n.phase));
        const highInd: usize = @intFromFloat(@mod(@ceil(n.phase), len));

        const fractional_distance: f32 = @rem(n.phase, 1);

        const result: f32 = std.math.lerp(n.wavetable[lowInd], n.wavetable[highInd], fractional_distance) * n.amp.get();

        n.phase += @as(f32, @floatFromInt(n.wavetable.len)) * n.pitch.get() / @as(f32, @floatFromInt(n.ctx.sample_rate));

        while (n.phase >= len) {
            n.phase -= len;
        }
        // store latest result
        n.buf = @bitCast(result);

        return result;
    }

    pub fn node(n: *TestWavetableOscNode) Node(f32) {
        return .{ .ptr = n, .nextFn = nextFn };
    }
};

const TestNode = struct {
    current: f32 = 0.0,
    ctx: ?*const AudioContext = null,

    pub fn nextFn(ptr: *anyopaque) f32 {
        var tn: *TestNode = @ptrCast(@alignCast(ptr));

        tn.current += 1.0;
        return @mod(tn.current, 10.0);
    }

    pub fn node(n: *TestNode) Node(f32) {
        return .{ .ptr = n, .nextFn = nextFn };
    }
};

// represents a generic processing step for audio, produces a Signal
pub fn Node(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        nextFn: *const fn (ptr: *anyopaque) T,

        const Self = @This();

        pub fn next(self: Self) T {
            return self.nextFn(self.ptr);
        }

        pub fn signal(n: Self) Signal(T) {
            return .{ .node = n };
        }
    };
}

const SignalValueTags = enum {
    static,
    node,
    ptr,
};

// Value provider for audio nodes
pub fn Signal(comptime T: type) type {
    return union(SignalValueTags) {
        static: T,
        node: Node(T),
        ptr: *const T,

        const Self = @This();

        pub fn get(s: Self) T {
            return switch (s) {
                .static => |val| val,
                .node => |n| n.next(),
                .ptr => |ptr| ptr.*,
            };
        }
    };
}

test "Node" {
    var test_node = TestNode{};
    var node = test_node.node();

    try testing.expectEqual(1.0, node.next());
    try testing.expectEqual(2.0, node.next());
}

test "Signal" {
    const static_signal: Signal(f32) = .{ .static = 2.0 };
    try testing.expectEqual(2.0, static_signal.get());
    try testing.expectEqual(2.0, static_signal.get());

    var test_node = TestNode{};
    var node = test_node.node();
    var src_signal: Signal(f32) = node.signal();

    try testing.expectEqual(1.0, src_signal.get());
    try testing.expectEqual(2.0, src_signal.get());
    try testing.expectEqual(3.0, src_signal.get());
    try testing.expectEqual(4.0, src_signal.get());

    var val: f32 = 1.0;
    const ptr_signal: Signal(f32) = .{ .ptr = &val };

    try testing.expectEqual(1.0, ptr_signal.get());

    val = 5.0;
    try testing.expectEqual(5.0, ptr_signal.get());
}

test "Signal w/ context" {
    var context = AudioContext{
        .sample_rate = 44_100,
        .ticks = 0,
        .sink = null,
    };
    var node = TestNode{ .ctx = &context };

    var n = node.node();

    const src_signal: Signal(f32) = n.signal();

    context.sink = src_signal;

    try testing.expectEqual(1.0, context.next());
    try testing.expectEqual(2.0, context.next());
    try testing.expectEqual(3.0, context.next());
    try testing.expectEqual(4.0, context.next());
}
