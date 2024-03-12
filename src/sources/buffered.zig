const std = @import("std");
const main = @import("../main.zig");

pub const BufferIterator = struct {
    head: usize = 0,
    head_inc_counter: usize = 0,
    buf: main.AudioBuffer,
    target_sample_rate: u32 = 44_100,
    should_loop: bool = true,

    pub fn next(i: *BufferIterator) ?[]u8 {
        if (!i.hasNext()) {
            return null;
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

        return @constCast(slice);
    }

    pub fn hasNext(i: BufferIterator) bool {
        return (i.head + i.buf.format.frameSize()) < i.buf.buf.len * i.sample_rate_ratio();
    }

    fn sample_rate_ratio(i: BufferIterator) usize {
        return i.target_sample_rate / i.buf.format.sample_rate;
    }
};

test "bufferIterator" {
    // TK
}
