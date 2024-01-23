const std = @import("std");
const main = @import("../main.zig");

// should know channel count and sampleFmt
const BufferIterator = struct {
    head: usize = 0,
    buffer: *[]u8,
    sample_fmt: main.SampleFormat,
    channel_count: u8 = 1,

    const Self = @This();

    pub fn init(buf: *[]u8, sampleFmt: main.SampleFormat) Self {
        _ = sampleFmt;
        return .{ .buffer = buf };
    }

    pub fn next(self: Self) ?[]u8 {
        if (!self.hasNext()) {
            return null;
        }

        const slice = self.buffer[self.head..(self.head + self.sampleSize())];
        self.head += self.sampleSize();

        return slice;
    }

    fn sampleSize(self: Self) usize {
        return self.channel_count * self.sample_fmt.size();
    }

    pub fn hasNext(self: Self) bool {
        return (self.head + self.sampleSize()) < self.buffer.len;
    }
};

test "bufferIterator" {
    // TK
}
