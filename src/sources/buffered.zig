const std = @import("std");
const main = @import("../main.zig");

// TODO: move AudioBuffer somewhere more ergonomic
const wav = @import("../readers/wav.zig");

// should know channel count and sampleFmt
pub const BufferIterator = struct {
    head: usize = 0,
    head_inc_counter: usize = 0,
    buf: wav.AudioBuffer,
    target_sample_rate: u32 = 44_100,
    channel_count: u8 = 1,
    should_loop: bool = true,

    const Self = @This();

    pub fn init(buf: wav.AudioBuffer) Self {
        return .{ .buf = buf };
    }

    // returns frame as bytes
    pub fn next(self: *Self) ?[]u8 {
        if (!self.hasNext()) {
            return null;
        }

        // repeat samples based on ratio between actual and target sample rate
        const sample_rate_ratio: usize = self.target_sample_rate / self.buf.format.sample_rate;

        const slice = self.buf.buf[self.head..(self.head + self.buf.format.frameSize())];

        self.head_inc_counter += 1;
        if (self.head_inc_counter >= sample_rate_ratio) {
            self.head_inc_counter = 0;
            self.head += self.buf.format.frameSize();
        }

        if (self.head >= self.buf.buf.len and self.should_loop) {
            self.head = 0; // theoretically loops the buffer
            std.debug.print("BufferIterator: Looping buffer\n", .{});
        }

        return @constCast(slice);
    }

    pub fn hasNext(self: Self) bool {
        const sample_rate_ratio: usize = self.target_sample_rate / self.buf.format.sample_rate;
        return (self.head + self.buf.format.frameSize()) < self.buf.buf.len * sample_rate_ratio;
    }
};

test "bufferIterator" {
    // TK
}
