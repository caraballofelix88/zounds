const std = @import("std");
const signals = @import("../signals.zig");
const main = @import("../main.zig");

pub const BufferPlayback = struct {
    ctx: *const signals.GraphContext,
    id: []const u8 = "BufferPlayback",
    head: usize = 0,
    head_inc_counter: usize = 0,
    buf: main.AudioBuffer,

    should_loop: bool = true,

    out: signals.Signal = .{ .static = 0.0 },

    pub const ins = .{};
    pub const outs = .{.out};

    pub fn process(ptr: *anyopaque) void {
        const p: *BufferPlayback = @ptrCast(@alignCast(ptr));
        if (!p.hasNext()) {
            return;
        }

        const slice = p.buf.buf[p.head..(p.head + p.buf.format.frameSize())];

        // repeat samples based on ratio between actual and target sample rate
        p.head_inc_counter += 1;
        if (p.head_inc_counter >= p.sample_rate_ratio()) {
            p.head_inc_counter = 0;
            p.head += p.buf.format.frameSize();
        }

        if (p.head >= p.buf.buf.len and p.should_loop) {
            p.head = 0;
        }

        p.out.set(std.mem.bytesToValue(f32, slice));
    }

    fn hasNext(p: BufferPlayback) bool {
        return (p.head + p.buf.format.frameSize()) < p.buf.buf.len * p.sample_rate_ratio();
    }

    fn sample_rate_ratio(p: BufferPlayback) usize {
        return p.ctx.sample_rate / p.buf.format.sample_rate;
    }

    pub fn node(p: *BufferPlayback) signals.Node {
        return signals.Node.init(p, BufferPlayback);
    }
};
