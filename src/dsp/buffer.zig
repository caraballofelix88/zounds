const std = @import("std");
const signals = @import("../signals.zig");
const main = @import("../main.zig");

pub const Buffer = struct {
    ctx: *signals.Context,
    id: []const u8 = "bufff",
    head: usize = 0,
    head_inc_counter: usize = 0,
    buf: main.AudioBuffer,

    should_loop: bool = true,

    out: ?signals.Signal = null,

    pub const ins = .{};
    pub const outs = .{.out};

    pub fn process(ptr: *anyopaque) void {
        const i: *Buffer = @ptrCast(@alignCast(ptr));
        if (!i.hasNext() or i.out == null) {
            return;
        }

        const slice = i.buf.buf[i.head..(i.head + i.buf.format.frameSize())];

        // repeat samples based on ratio between actual and target sample rate
        i.head_inc_counter += 1;
        if (i.head_inc_counter >= i.sample_rate_ratio()) {
            i.head_inc_counter = 0;
            i.head += i.buf.format.frameSize();
        }

        if (i.head >= i.buf.buf.len and i.should_loop) {
            i.head = 0;
        }

        i.out.?.set(std.mem.bytesToValue(f32, slice));
    }

    fn hasNext(i: Buffer) bool {
        return (i.head + i.buf.format.frameSize()) < i.buf.buf.len * i.sample_rate_ratio();
    }

    fn sample_rate_ratio(b: Buffer) usize {
        return b.ctx.sample_rate / b.buf.format.sample_rate;
    }

    pub fn node(b: *Buffer) signals.Node {
        return signals.Node.init(b, Buffer);
    }
};
